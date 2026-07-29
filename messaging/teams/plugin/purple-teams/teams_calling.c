/*
 * Teams Plugin for libpurple/Pidgin - NGC (NextGenCalling) voice calling.
 * webOS Synergy Revival.  See teams_calling.h for the protocol overview.
 *
 * SCOPE (this file, initial drop):
 *   - CAPTURE: dump every raw NGC call notification (SDP blob, udpKey, links, codecs) to
 *     /media/internal/teams-call-capture.log  -> the ground truth for finishing media.
 *   - PARSE:   turn the callNotification into a TeamsCall (peer, sdp, key, ticket, links).
 *   - STATE:   drive incoming/dialing/active/disconnected and notify the Phone-app bridge.
 *   - CONTROL: reject (POST to the reject link) works today; answer posts the SDP answer to
 *     the mediaAnswer/attach link once the media engine produces one; dial (outgoing) is a
 *     documented stub (the outgoing-call control flow needs an outgoing-call capture).
 *   - MEDIA:   handed to the out-of-process teams_media engine; traced stubs until the
 *     capture confirms codec (SILK/Satin/G.722) + MS-TURN ticket auth.
 *
 * Everything marked "CONFIRM WITH CAPTURE" is a best-effort guess from Eion Robb's
 * reverse-engineered comments that a single real call will pin down.
 */

#include "teams_calling.h"
#include "teams_connection.h"
#include "teams_util.h"

#include <purple.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

#define TEAMS_CALL_LOG      "/media/internal/teams-call.log"
#define TEAMS_CALL_CAPTURE  "/media/internal/teams-call-capture.log"

/* ------------------------------------------------------------------ logging */

void
teams_call_log(const char *fmt, ...)
{
	FILE *f = fopen(TEAMS_CALL_LOG, "a");
	va_list ap;
	time_t now = time(NULL);
	char ts[32];
	struct tm *tm = localtime(&now);
	strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);

	if (f) {
		fprintf(f, "%s ", ts);
		va_start(ap, fmt);
		vfprintf(f, fmt, ap);
		va_end(ap);
		fputc('\n', f);
		fclose(f);
	}
	/* also to purple debug for the desktop build */
	{
		char buf[1024];
		va_start(ap, fmt);
		vsnprintf(buf, sizeof(buf), fmt, ap);
		va_end(ap);
		purple_debug_info("teams", "call: %s\n", buf);
	}
}

/* ------------------------------------------------------- NULL-safe JSON getters
 * NGC notifications are reverse-engineered and fields drop in/out between tenants;
 * json-glib's own getters assert on a missing/typed-wrong member, so guard everything. */

static const gchar *
sget(JsonObject *o, const gchar *k)
{
	JsonNode *n;
	if (!o || !json_object_has_member(o, k)) return NULL;
	n = json_object_get_member(o, k);
	if (n && JSON_NODE_HOLDS_VALUE(n)) return json_node_get_string(n);
	return NULL;
}

static JsonObject *
oget(JsonObject *o, const gchar *k)
{
	JsonNode *n;
	if (!o || !json_object_has_member(o, k)) return NULL;
	n = json_object_get_member(o, k);
	if (n && JSON_NODE_HOLDS_OBJECT(n)) return json_node_get_object(n);
	return NULL;
}

/* --------------------------------------------------------- state / media hooks */

static TeamsCallStateCb g_state_cb = NULL;

void
teams_calling_set_state_cb(TeamsCallStateCb cb)
{
	g_state_cb = cb;
}

/* ---- media engine integration (teams_media, out-of-process) -----------------------------
 * On answer we: parse the offer SDP (peer ice-ufrag/pwd, a=crypto GCM key, opus PT, candidates),
 * spawn `teams_media --answer`, feed it START + the peer candidates, read back OUR ice creds +
 * TX SRTP key + local candidates, build an SDP answer and POST it to links.attach. teams_media
 * does the ICE + SRTP + Opus <-> ALSA voip. FIRST-ATTEMPT wiring - the exact answer-SDP shape and
 * the POST body/auth need on-device iteration (heavily logged). */
#define TEAMS_MEDIA_BIN "/media/internal/teams_media"

typedef struct {
	TeamsCall  *call;
	GPid        pid;
	int         in_fd;         /* -> child stdin */
	GIOChannel *out_ch;        /* <- child stdout */
	guint       out_watch;
	gchar      *our_ufrag, *our_pwd, *our_txkey;
	GString    *our_cands;     /* accumulated "candidate:..." lines, one per line */
	gboolean    ready, answered;
	guint       answer_timer;
	gboolean    is_caller;      /* TRUE = outgoing (we build+POST the offer via cpconv) */
	gchar      *callagent_id;   /* our client-generated callAgent uuid (outgoing) */
} TeamsMediaProc;

/* POST JSON to a flightproxy/calling URL WITH the x-skypetoken auth header (teams_post_or_get does
 * not add it for api.flightproxy.skype.com -> "Anonymous access is not allowed" 403). Logs the
 * response. Used for both the cpconv create (offer) and the mediaAnswer/attach POST (answer). */
static void
flightproxy_resp_cb(PurpleHttpConnection *hc, PurpleHttpResponse *resp, gpointer u)
{
	int code; size_t len = 0; const gchar *data;
	(void) hc; (void) u;
	code = purple_http_response_get_code(resp);
	data = purple_http_response_get_data(resp, &len);
	teams_call_log("FLIGHTPROXY resp code=%d body=%.300s", code, data ? data : "(none)");
}

/* Teams calling client identity (matches teams.live.com's SkypeSpacesWeb TFL client string). */
#define TEAMS_SKYPE_CLIENT "SkypeSpaces/1415/26070217343/os=linux; osVer=undefined; " \
	"deviceType=computer; browser=chrome; browserVer=150.0.0.0/TsCallingVersion=2026.24.01.6/Ovb=0"

/* Full form: POST with the calling headers + a caller-supplied response callback and user data.
 * cb may be NULL (falls back to flightproxy_resp_cb which just logs). */
static void
flightproxy_post_cb(TeamsAccount *sa, const gchar *url, const gchar *body,
                    PurpleHttpCallback cb, gpointer user)
{
	gchar *chain = purple_uuid_random(), *msgid = purple_uuid_random();
	PurpleHttpRequest *req = purple_http_request_new(url);
	purple_http_request_set_method(req, "POST");
	purple_http_request_set_keepalive_pool(req, sa->keepalive_pool);
	purple_http_request_header_set(req, "Content-Type", "application/json");
	purple_http_request_header_set(req, "X-Skypetoken", sa->skype_token);
	/* calling backend rejects requests without a client identity as 400 Bad Request */
	purple_http_request_header_set(req, "X-Microsoft-Skype-Client", TEAMS_SKYPE_CLIENT);
	purple_http_request_header_set(req, "X-Microsoft-Skype-Chain-Id", chain);
	purple_http_request_header_set(req, "X-Microsoft-Skype-Message-Id", msgid);
	purple_http_request_header_set(req, "ms-teams-ring", "general");
	purple_http_request_set_contents(req, body, strlen(body));
	purple_http_request(sa->pc, req, cb ? cb : flightproxy_resp_cb, user);
	purple_http_request_unref(req);
	g_free(chain); g_free(msgid);
}

static void
flightproxy_post(TeamsAccount *sa, const gchar *url, const gchar *body)
{
	flightproxy_post_cb(sa, url, body, NULL, NULL);
}

/* build a callAgent trouter control path: <surl>callAgent/<agent>/<hash8>/<kind>/<name>/ */
static gchar *
callagent_path(TeamsCall *call, const char *agent, const char *kind, const char *name)
{
	gchar *hash = g_strdup_printf("%08x", g_random_int());
	gchar *surl = call->sa->trouter_surl ? call->sa->trouter_surl : "";
	gchar *p = g_strdup_printf("%scallAgent/%s/%s/%s/%s/", surl, agent, hash, kind, name);
	g_free(hash);
	return p;
}

static TeamsMediaProc *g_mproc;

/* return the value after "a=<prefix>:" on the first matching line (newly-allocated), or NULL */
static gchar *
sdp_line_val(const char *sdp, const char *prefix)
{
	gchar **lines, *ret = NULL;
	int i;
	if (!sdp) return NULL;
	lines = g_strsplit(sdp, "\n", -1);
	for (i = 0; lines[i]; i++) {
		gchar *l = g_strstrip(lines[i]);
		if (g_str_has_prefix(l, prefix)) { ret = g_strdup(l + strlen(prefix)); break; }
	}
	g_strfreev(lines);
	return ret;
}

/* the AEAD_AES_256_GCM inline key (base64, up to the '|') from the offer's a=crypto lines */
static gchar *
sdp_gcm_key(const char *sdp)
{
	gchar **lines; int i; gchar *ret = NULL;
	if (!sdp) return NULL;
	lines = g_strsplit(sdp, "\n", -1);
	for (i = 0; lines[i]; i++) {
		gchar *l = g_strstrip(lines[i]);
		if (strstr(l, "AEAD_AES_256_GCM") && strstr(l, "inline:")) {
			gchar *k = strstr(l, "inline:") + 7;
			gchar *bar = strchr(k, '|');
			ret = bar ? g_strndup(k, bar - k) : g_strdup(k);
			break;
		}
	}
	g_strfreev(lines);
	return ret;
}

static void teams_calling_post_answer(TeamsCall *call, const char *answer_sdp);
static void call_http_post(TeamsAccount *sa, const gchar *full_url, const gchar *body);

/* dump the exact SDP answer we send, for offline diffing against the web client's accepted answer */
static void
teams_calling_log_sdp(const char *sdp)
{
	g_file_set_contents("/media/internal/teams-answer.sdp", sdp ? sdp : "", -1, NULL);
}

static void answer_ok_cb(TeamsAccount *sa, JsonNode *node, gpointer u);
static void answer_err_cb(TeamsAccount *sa, const gchar *data, gssize len, gpointer u);

/* build the SDP answer from our media params + the offer (SDES-GCM path; the offer supports both
 * SDES a=crypto and DTLS, and our engine keys via SDES). Shape mirrors the web client's accepted
 * answer: BUNDLE + mid:audio_0 + rtcp-mux + label, a=crypto instead of DTLS fingerprint. Then kicks
 * off the two-step media-controller handshake (attach -> parse acceptance link -> accept w/ SDP). */
static void
media_send_answer(TeamsMediaProc *mp)
{
	TeamsCall *call = mp->call;
	GString *a;
	gchar *our_ip = NULL; int our_port = 3480;

	if (mp->answered || !mp->our_ufrag || !mp->our_pwd || !mp->our_txkey) return;
	mp->answered = TRUE;

	/* Derive our OWN connection address for c=/m= from the first UDP host candidate (NOT the offerer's
	 * relay IP - advertising the peer's address as ours confuses the NGC validator). */
	if (mp->our_cands) {
		gchar **cl = g_strsplit(mp->our_cands->str, "\n", -1); int i;
		for (i = 0; cl[i]; i++) {
			/* "candidate:<f> <comp> UDP <pri> <ip> <port> typ host ..." */
			if (strstr(cl[i], " UDP ") && strstr(cl[i], "typ host")) {
				gchar **t = g_strsplit(g_strstrip(cl[i]), " ", -1);
				if (t[0] && t[1] && t[2] && t[3] && t[4] && t[5]) {
					our_ip = g_strdup(t[4]); our_port = atoi(t[5]);
				}
				g_strfreev(t);
				break;
			}
		}
		g_strfreev(cl);
	}

	a = g_string_new("");
	g_string_append(a, "v=0\r\n");
	g_string_append_printf(a, "o=- %u 2 IN IP4 %s\r\n", g_random_int(), our_ip ? our_ip : "127.0.0.1");
	g_string_append(a, "s=-\r\n");
	g_string_append(a, "b=CT:4000\r\nt=0 0\r\n");
	g_string_append(a, "a=extmap-allow-mixed\r\n");
	g_string_append(a, "a=msid-semantic: WMS *\r\n");
	g_string_append(a, "a=group:BUNDLE audio_0 video_1\r\n");
	g_string_append_printf(a, "m=audio %d RTP/SAVP 102 9 0 8 101\r\n", our_port);
	g_string_append_printf(a, "c=IN IP4 %s\r\n", our_ip ? our_ip : "127.0.0.1");
	g_string_append(a, "a=rtpmap:102 opus/48000/2\r\n");
	g_string_append(a, "a=rtpmap:9 G722/8000\r\n");
	g_string_append(a, "a=rtpmap:0 PCMU/8000\r\n");
	g_string_append(a, "a=rtpmap:8 PCMA/8000\r\n");
	g_string_append(a, "a=rtpmap:101 telephone-event/8000\r\n");
	g_string_append(a, "a=fmtp:102 minptime=10;useinbandfec=1\r\n");
	g_string_append(a, "a=mid:audio_0\r\n");
	g_string_append(a, "a=sendrecv\r\n");
	g_string_append_printf(a, "a=ice-ufrag:%s\r\n", mp->our_ufrag);
	g_string_append_printf(a, "a=ice-pwd:%s\r\n", mp->our_pwd);
	g_string_append_printf(a, "a=crypto:4 AEAD_AES_256_GCM inline:%s|2^31\r\n", mp->our_txkey);
	/* Emit UDP candidates only - Teams' NGC parser can reject the whole answer over ICE-TCP lines. */
	if (mp->our_cands) {
		gchar **cl = g_strsplit(mp->our_cands->str, "\n", -1); int i;
		for (i = 0; cl[i]; i++)
			if (cl[i][0] && strstr(cl[i], " UDP ")) g_string_append_printf(a, "a=%s\r\n", cl[i]);
		g_strfreev(cl);
	}
	g_string_append(a, "a=ice-options:trickle\r\n");
	g_string_append(a, "a=rtcp-mux\r\n");
	g_string_append(a, "a=label:main-audio\r\n");

	/* The offer has a second m-line (m=video, BUNDLE audio_0 video_1). SDP offer/answer requires the
	 * answer to mirror the offer's m-lines in count+order, so we MUST emit a corresponding video line
	 * or the peer rejects the whole answer (FinalAnswerError 406/4122). We don't do video: mark it
	 * inactive, bundled onto the audio transport (same ice-ufrag/pwd/crypto). */
	g_string_append_printf(a, "m=video %d RTP/SAVP 107\r\n", our_port);
	g_string_append_printf(a, "c=IN IP4 %s\r\n", our_ip ? our_ip : "127.0.0.1");
	g_string_append(a, "a=rtpmap:107 H264/90000\r\n");
	g_string_append(a, "a=fmtp:107 profile-level-id=42C02A;packetization-mode=1\r\n");
	g_string_append(a, "a=mid:video_1\r\n");
	g_string_append(a, "a=inactive\r\n");
	g_string_append_printf(a, "a=ice-ufrag:%s\r\n", mp->our_ufrag);
	g_string_append_printf(a, "a=ice-pwd:%s\r\n", mp->our_pwd);
	g_string_append_printf(a, "a=crypto:4 AEAD_AES_256_GCM inline:%s|2^31\r\n", mp->our_txkey);
	g_string_append(a, "a=rtcp-mux\r\n");
	g_string_append(a, "a=label:main-video\r\n");

	g_free(call->our_answer_sdp);
	call->our_answer_sdp = g_strdup(a->str);
	teams_call_log("ANSWER SDP built (%d bytes) - starting attach->accept handshake", (int) a->len);
	teams_calling_log_sdp(call->our_answer_sdp);   /* dump full answer for offline diffing */
	teams_calling_post_answer(call, a->str);   /* now = attach then accept */
	g_string_free(a, TRUE);
	g_free(our_ip);
}

/* CALLER: build the OFFER SDP from our media params + POST the cpconv create request to place the
 * call (mirrors the teams.live.com web client's api/v2/cpconv flow). FIRST-ATTEMPT. */
static void
media_send_offer(TeamsMediaProc *mp)
{
	TeamsCall *call = mp->call;
	const char *agent = mp->callagent_id;
	GString *sdp, *body;
	gchar *offer_esc, *legid, *epid, *pid, *to_pid;
	int i;
	if (mp->answered || !mp->our_ufrag || !mp->our_pwd || !mp->our_txkey) return;
	mp->answered = TRUE;

	sdp = g_string_new("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nb=CT:4000\r\nt=0 0\r\na=group:BUNDLE 0\r\n");
	g_string_append(sdp, "m=audio 3480 RTP/SAVP 102 9 0 8\r\nc=IN IP4 0.0.0.0\r\n");
	g_string_append(sdp, "a=rtpmap:102 opus/48000/2\r\na=rtpmap:9 G722/8000\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n");
	g_string_append(sdp, "a=fmtp:102 minptime=10;useinbandfec=1\r\na=rtcp-mux\r\na=mid:0\r\na=sendrecv\r\na=label:main-audio\r\n");
	g_string_append_printf(sdp, "a=ice-ufrag:%s\r\na=ice-pwd:%s\r\n", mp->our_ufrag, mp->our_pwd);
	g_string_append_printf(sdp, "a=crypto:4 AEAD_AES_256_GCM inline:%s|2^31\r\n", mp->our_txkey);
	if (mp->our_cands) { gchar **cl = g_strsplit(mp->our_cands->str, "\n", -1);
		for (i = 0; cl[i]; i++) if (cl[i][0]) g_string_append_printf(sdp, "a=%s\r\n", cl[i]);
		g_strfreev(cl); }

	offer_esc = g_strescape(sdp->str, "");
	legid = g_strdup_printf("%08X%08X%08X%08X", g_random_int(), g_random_int(), g_random_int(), g_random_int());
	/* endpointId must be our REGISTERED calling endpoint so callAgent response frames route back. */
	epid = g_strdup(call->sa->endpoint ? call->sa->endpoint : "");
	pid = purple_uuid_random(); to_pid = purple_uuid_random();

/* append "name":"<callagent path>", to body for the given control kind (conversation|call) */
#define AGL(kind, nm) do { gchar *_p = callagent_path(call, agent, kind, nm); \
	g_string_append_printf(body, "\"%s\":\"%s\",", nm, _p); g_free(_p); } while (0)

	/* conversationRequest holds ONLY {type,subject,suppressDialout,applicationType,roster,properties,links};
	 * participants/callInvitation/endpoint* are TOP-LEVEL siblings of conversationRequest (not nested). */
	body = g_string_new("{\"conversationRequest\":{\"conversationType\":null,\"subject\":null,"
		"\"suppressDialout\":false,\"applicationType\":\"TFL\",");
	{ gchar *r = callagent_path(call, agent, "conversation", "rosterUpdate");
	  g_string_append_printf(body, "\"roster\":{\"type\":\"Delta\",\"rosterUpdate\":\"%s\"},", r); g_free(r); }
	g_string_append(body, "\"properties\":{\"allowConversationWithoutHost\":true,"
		"\"enableGroupCallEventMessages\":true,\"enableGroupCallUpgradeMessage\":false,"
		"\"enableGroupCallMeetupGeneration\":false},");
	g_string_append(body, "\"links\":{");
	AGL("conversation", "conversationEnd"); AGL("conversation", "conversationUpdate");
	AGL("conversation", "localParticipantUpdate"); AGL("conversation", "addParticipantSuccess");
	AGL("conversation", "addParticipantFailure"); AGL("conversation", "addModalitySuccess");
	AGL("conversation", "addModalityFailure"); AGL("conversation", "confirmUnmute");
	AGL("conversation", "receiveMessage");
	g_string_truncate(body, body->len - 1);   /* drop trailing comma */
	g_string_append(body, "}},");              /* close links, close conversationRequest */

	/* ---- top-level siblings ---- */
	g_string_append(body, "\"contentSharing\":null,");
	g_string_append_printf(body, "\"participants\":{\"from\":{\"id\":\"8:%s\",\"displayName\":\"webOS\","
		"\"endpointId\":\"%s\",\"participantId\":\"%s\",\"languageId\":\"en-us\"},",
		call->sa->username ? call->sa->username : "", epid, pid);
	g_string_append_printf(body, "\"to\":[{\"id\":\"%s\",\"participantId\":\"%s\"}]},",
		call->peer_mri ? call->peer_mri : "", to_pid);
	g_string_append(body, "\"capabilities\":null,\"endpointCapabilities\":73463,"
		"\"clientEndpointCapabilities\":42876960,\"endpointMetadata\":{\"holographicCapabilities\":3},"
		"\"groupContext\":null,\"groupChat\":null,\"meetingInfo\":null,\"meetingData\":null,"
		"\"endpointState\":{\"endpointStateSequenceNumber\":2,\"endpointProperties\":"
		"{\"additionalEndpointProperties\":{\"infoShownInReportMode\":\"FullInformation\"}}},");
	g_string_append(body, "\"callInvitation\":{\"callModalities\":[\"Audio\"],\"replaces\":null,"
		"\"transferor\":null,\"clientTransferContext\":null,\"customContext\":null,\"links\":{");
	AGL("call", "progress"); AGL("call", "mediaAnswer"); AGL("call", "acceptance");
	AGL("call", "redirection"); AGL("call", "end");
	g_string_truncate(body, body->len - 1);
	g_string_append(body, "},\"clientContentForMediaController\":{");
	AGL("call", "controlVideoStreaming"); AGL("call", "csrcInfo");
	g_string_truncate(body, body->len - 1);
	g_string_append(body, "},\"pstnContent\":{\"emergencyCallCountry\":\"\","
		"\"platformName\":\"" TEAMS_SKYPE_CLIENT "\",\"publicApiCall\":false},\"emergencyContent\":null,");
	g_string_append_printf(body, "\"mediaContent\":{\"blob\":\"%s\",\"contentType\":\"application/sdp-ngc-1.0\","
		"\"requiredFeatures\":\"nonByPass\",\"clientLocation\":\"NL\",\"mediaLegId\":\"%s\"},",
		offer_esc, legid);
	g_string_append(body, "\"voicemailSettings\":{},\"locationContent\":null,"
		"\"networkContent\":null,\"areaContent\":null},");   /* close callInvitation */
	g_string_append(body, "\"debugContent\":{},\"participantPropertyBag\":{}}");   /* close outer */
#undef AGL

	teams_call_log("dial: OFFER built (%d bytes sdp, %d body), POSTing cpconv to place call to %s",
	               (int) sdp->len, (int) body->len, call->peer_mri ? call->peer_mri : "?");
	flightproxy_post(call->sa, "https://api.flightproxy.skype.com/api/v2/cpconv", body->str);

	g_string_free(sdp, TRUE); g_string_free(body, TRUE);
	g_free(offer_esc); g_free(legid); g_free(epid); g_free(pid); g_free(to_pid);
}

static gboolean
media_answer_timeout(gpointer user)
{
	TeamsMediaProc *mp = user;
	mp->answer_timer = 0;
	if (mp->is_caller) media_send_offer(mp);   /* outgoing: build+POST the offer (place the call) */
	else               media_send_answer(mp);  /* incoming: build+POST the answer */
	return G_SOURCE_REMOVE;
}

/* read UFRAG/PWD/TXKEY/CAND/READY/AUDIOD from teams_media's stdout */
static gboolean
media_on_output(GIOChannel *ch, GIOCondition cond, gpointer user)
{
	TeamsMediaProc *mp = user;
	gchar *line = NULL; gsize len = 0;
	if (cond & (G_IO_HUP | G_IO_ERR)) return FALSE;
	while (g_io_channel_read_line(ch, &line, &len, NULL, NULL) == G_IO_STATUS_NORMAL && line) {
		g_strchomp(line);
		if (g_str_has_prefix(line, "UFRAG ")) { g_free(mp->our_ufrag); mp->our_ufrag = g_strdup(line + 6); }
		else if (g_str_has_prefix(line, "PWD ")) { g_free(mp->our_pwd); mp->our_pwd = g_strdup(line + 4); }
		else if (g_str_has_prefix(line, "TXKEY ")) { g_free(mp->our_txkey); mp->our_txkey = g_strdup(line + 6); }
		else if (g_str_has_prefix(line, "CAND ")) { if (mp->our_cands) g_string_append_printf(mp->our_cands, "%s\n", line + 5); }
		else if (g_str_has_prefix(line, "READY")) {
			mp->ready = TRUE;
			teams_call_log("media engine READY; gathering candidates before answer");
			/* give ICE ~1.5s to gather candidates, then build + POST the answer */
			if (!mp->answer_timer) mp->answer_timer = g_timeout_add(1500, media_answer_timeout, mp);
		}
		else if (g_str_has_prefix(line, "ERR ")) teams_call_log("media engine ERR: %s", line + 4);
		else if (g_str_has_prefix(line, "AUDIOD ")) teams_call_log("media audiod %s", line + 7);
		g_free(line); line = NULL;
	}
	return TRUE;
}

static void
teams_media_start(TeamsCall *call)
{
	TeamsMediaProc *mp;
	gchar *ruf, *rpw, *rxkey, *pt_s = NULL;
	int pt = 102;
	gchar **lines; int i;
	const gchar *argv[] = { TEAMS_MEDIA_BIN, "--answer", NULL };
	/* teams_media needs the WPE gst runtime env (it runs patchelf'd to the wpe-glibc loader). The
	 * transport already has LD_LIBRARY_PATH from imwrap.sh; add the gst plugin path + registry. */
	const gchar *W = "/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/lib";
	gchar *gstenv = g_strdup_printf("GST_PLUGIN_SYSTEM_PATH_1_0=%s/gstreamer-1.0", W);
	gchar *regenv = g_strdup("GST_REGISTRY=/media/internal/teams-gst-registry.bin");
	gchar **envp = g_get_environ();
	GError *err = NULL;
	GPid pid; int in_fd = -1, out_fd = -1;

	ruf   = sdp_line_val(call->sdp_offer, "a=ice-ufrag:");
	rpw   = sdp_line_val(call->sdp_offer, "a=ice-pwd:");
	rxkey = sdp_gcm_key(call->sdp_offer);
	pt_s  = sdp_line_val(call->sdp_offer, "a=rtpmap:"); /* not exact; opus is 102 in practice */
	g_free(pt_s);
	if (!ruf || !rpw || !rxkey) {
		teams_call_log("media_start: offer missing ice/crypto (uf=%d pw=%d key=%d) - cannot answer",
		               ruf != NULL, rpw != NULL, rxkey != NULL);
		g_free(ruf); g_free(rpw); g_free(rxkey); g_strfreev(envp); g_free(gstenv); g_free(regenv);
		return;
	}

	envp = g_environ_setenv(envp, "GST_PLUGIN_SYSTEM_PATH_1_0", strchr(gstenv, '=') + 1, TRUE);
	envp = g_environ_setenv(envp, "GST_REGISTRY", strchr(regenv, '=') + 1, TRUE);
	/* capture detailed GStreamer errors (esp. srtp decrypt / rtp depay) to a file for diagnosis */
	envp = g_environ_setenv(envp, "GST_DEBUG", "2,srtp*:5,rtpopusdepay:5,opusdec:4,alsasink:5,nicesrc:4", TRUE);
	envp = g_environ_setenv(envp, "GST_DEBUG_FILE", "/media/internal/teams-gst.log", TRUE);
	envp = g_environ_setenv(envp, "GST_DEBUG_NO_COLOR", "1", TRUE);
	/* ALSA "voip"/"voipsource" are PulseAudio PCMs defined ONLY in the system /etc/asound.conf, which
	 * only the SYSTEM libasound reads. The wpe-252 libasound (in our RUNPATH) uses its own config that
	 * lacks them -> "Unknown PCM voip". Force the system libasound (via LD_PRELOAD, same as the
	 * transport) + the system ALSA config so alsasink/alsasrc can open voip/voipsource -> PulseAudio. */
	envp = g_environ_setenv(envp, "LD_PRELOAD",
		"/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/libstdc++.so.6 "
		"/media/cryptofs/wpe-glibc/lib/librt.so.1 /usr/lib/libasound.so.2", TRUE);
	envp = g_environ_setenv(envp, "ALSA_CONFIG_PATH", "/usr/share/alsa/alsa.conf", TRUE);
	envp = g_environ_setenv(envp, "ALSA_PLUGIN_DIR", "/usr/lib/alsa-lib", TRUE);

	if (!g_spawn_async_with_pipes(NULL, (gchar **) argv, envp,
	                              G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL,
	                              &pid, &in_fd, &out_fd, NULL, &err)) {
		teams_call_log("media_start: spawn %s failed: %s", TEAMS_MEDIA_BIN, err ? err->message : "?");
		if (err) g_error_free(err);
		g_free(ruf); g_free(rpw); g_free(rxkey); g_strfreev(envp); g_free(gstenv); g_free(regenv);
		return;
	}
	g_strfreev(envp); g_free(gstenv); g_free(regenv);

	mp = g_new0(TeamsMediaProc, 1);
	mp->call = call; mp->pid = pid; mp->in_fd = in_fd;
	mp->our_cands = g_string_new("");
	mp->out_ch = g_io_channel_unix_new(out_fd);
	g_io_channel_set_flags(mp->out_ch, G_IO_FLAG_NONBLOCK, NULL);
	mp->out_watch = g_io_add_watch(mp->out_ch, G_IO_IN | G_IO_HUP | G_IO_ERR, media_on_output, mp);
	g_mproc = mp;

	/* Give the engine a STUN server so it gathers server-reflexive (srflx) candidates - host-only
	 * ICE can't traverse NAT to Teams' relay. Teams' media relay (udpTransport, :3478) also answers
	 * STUN binding requests, so point STUN at it. Must precede START. */
	if (call->udp_transport) {
		const gchar *h = call->udp_transport;
		gchar *hc, *slash, *colon; int rport = 3478;
		if (g_str_has_prefix(h, "udp://")) h += 6;
		hc = g_strdup(h);
		if ((slash = strchr(hc, '/'))) *slash = '\0';
		if ((colon = strrchr(hc, ':'))) { rport = atoi(colon + 1); *colon = '\0'; }
		{ gchar *r = g_strdup_printf("RELAY stun %s %d\n", hc, rport);
		  if (write(in_fd, r, strlen(r)) < 0) {} g_free(r); }
		teams_call_log("media_start: RELAY stun %s %d", hc, rport);
		g_free(hc);
	}

	/* START <rx_master_b64> <remote_ufrag> <remote_pwd> <pt> */
	{ gchar *s = g_strdup_printf("START %s %s %s %d\n", rxkey, ruf, rpw, pt);
	  if (write(in_fd, s, strlen(s)) < 0) teams_call_log("media_start: write START failed"); g_free(s); }
	/* feed the peer's ICE candidates from the offer */
	lines = g_strsplit(call->sdp_offer, "\n", -1);
	for (i = 0; lines[i]; i++) {
		gchar *l = g_strstrip(lines[i]);
		if (g_str_has_prefix(l, "a=candidate:")) {
			gchar *r = g_strdup_printf("RCAND %s\n", l + 2); /* strip "a=" -> "candidate:..." */
			if (write(in_fd, r, strlen(r)) < 0) {} g_free(r);
		}
	}
	g_strfreev(lines);
	teams_call_log("media_start: spawned teams_media pid=%d, START sent (pt=%d relay=%s)", (int) pid, pt,
	               call->udp_transport ? call->udp_transport : "(none)");
	g_free(ruf); g_free(rpw); g_free(rxkey);
}

static void
teams_media_stop(void)
{
	TeamsMediaProc *mp = g_mproc;
	if (!mp) return;
	g_mproc = NULL;
	if (mp->answer_timer) g_source_remove(mp->answer_timer);
	if (mp->in_fd >= 0) { const char *s = "STOP\n"; if (write(mp->in_fd, s, 5) < 0) {} close(mp->in_fd); }
	if (mp->out_watch) g_source_remove(mp->out_watch);
	if (mp->out_ch) g_io_channel_unref(mp->out_ch);
	if (mp->pid) { g_spawn_close_pid(mp->pid); }
	g_string_free(mp->our_cands, TRUE);
	g_free(mp->our_ufrag); g_free(mp->our_pwd); g_free(mp->our_txkey); g_free(mp->callagent_id);
	g_free(mp);
	teams_call_log("media stopped");
}

/* POST the SDP answer to the call's attach link (resolves the mediaAnswer "cc://ma"). Body shape is
 * a best-effort mirror of the offer's mediaContent - CONFIRM/iterate against a web-client answer. */
/* log whether Teams accepted our SDP answer - critical: if rejected, Teams never runs ICE with us. */
static void answer_ok_cb(TeamsAccount *sa, JsonNode *node, gpointer u)
{ (void)sa;(void)u; { gchar *s = node ? json_to_string(node, FALSE) : NULL;
  teams_call_log("ANSWER POST: ACCEPTED (2xx) resp=%.200s", s ? s : "(empty)"); g_free(s); } }
static void answer_err_cb(TeamsAccount *sa, const gchar *data, gssize len, gpointer u)
{ (void)sa;(void)len;(void)u; teams_call_log("ANSWER POST: REJECTED/err resp=%.260s", data ? data : "(no body)"); }

/* Step 2: POST the accept (with our SDP answer) to the acceptance link parsed from the attach
 * response. Body = callAcceptance{acceptedBy, acceptedCallModalities, caps, mediaContent{blob,...}}. */
static void
teams_calling_post_accept(TeamsCall *call, const gchar *acceptance_url)
{
	TeamsAccount *sa = call->sa;
	const char *agent = call->callagent_id;
	gchar *esc, *legid, *body;
	gchar *l_reneg, *l_xfer, *l_repl, *l_bal, *l_retgt, *l_ctlvid, *l_updmd, *cc_ctlvid, *cc_csrc;
	if (!call->our_answer_sdp) { teams_call_log("accept: no answer SDP"); return; }
	esc = g_strescape(call->our_answer_sdp, "");
	legid = g_strdup_printf("%08X%08X%08X%08X", g_random_int(), g_random_int(), g_random_int(), g_random_int());
	l_reneg  = callagent_path(call, agent, "call", "mediaRenegotiation");
	l_xfer   = callagent_path(call, agent, "call", "transfer");
	l_repl   = callagent_path(call, agent, "call", "replacement");
	l_bal    = callagent_path(call, agent, "call", "balanceUpdate");
	l_retgt  = callagent_path(call, agent, "call", "retargetCompletion");
	l_ctlvid = callagent_path(call, agent, "call", "controlVideoStreaming");
	l_updmd  = callagent_path(call, agent, "call", "updateMediaDescriptions");
	cc_ctlvid = callagent_path(call, agent, "call", "controlVideoStreaming");
	cc_csrc   = callagent_path(call, agent, "call", "csrcInfo");
	body = g_strdup_printf(
		"{\"callAcceptance\":{"
		  "\"acceptedBy\":{\"id\":\"8:%s\",\"displayName\":\"webOS\",\"endpointId\":\"%s\","
		    "\"participantId\":\"%s\",\"languageId\":\"en-us\"},"
		  "\"acceptedCallModalities\":[\"Audio\"],"
		  "\"capabilities\":null,\"endpointCapabilities\":73463,\"clientEndpointCapabilities\":42876960,"
		  "\"links\":{\"mediaRenegotiation\":\"%s\",\"transfer\":\"%s\",\"replacement\":\"%s\","
		    "\"balanceUpdate\":\"%s\",\"retargetCompletion\":\"%s\",\"controlVideoStreaming\":\"%s\","
		    "\"updateMediaDescriptions\":\"%s\"},"
		  "\"clientContentForMediaController\":{\"controlVideoStreaming\":\"%s\",\"csrcInfo\":\"%s\"},"
		  "\"mediaContent\":{\"blob\":\"%s\",\"contentType\":\"application/sdp-ngc-1.0\","
		    "\"clientLocation\":\"NL\",\"mediaLegId\":\"%s\"},"
		  "\"pstnContent\":{\"emergencyCallCountry\":\"\",\"platformName\":\"" TEAMS_SKYPE_CLIENT "\","
		    "\"publicApiCall\":false},"
		  "\"callKeepAliveInterval\":null,"
		  "\"applicationType\":\"TFL\"}}",
		sa->username ? sa->username : "",
		call->our_endpoint_id ? call->our_endpoint_id : "",
		call->our_participant_id ? call->our_participant_id : "",
		l_reneg, l_xfer, l_repl, l_bal, l_retgt, l_ctlvid, l_updmd, cc_ctlvid, cc_csrc,
		esc, legid);
	teams_call_log("accept -> POST %d-byte body to acceptance link", (int) strlen(body));
	flightproxy_post_cb(sa, acceptance_url, body, flightproxy_resp_cb, NULL);
	g_free(esc); g_free(legid); g_free(body);
	g_free(l_reneg); g_free(l_xfer); g_free(l_repl); g_free(l_bal); g_free(l_retgt);
	g_free(l_ctlvid); g_free(l_updmd); g_free(cc_ctlvid); g_free(cc_csrc);
}

/* Step 1 response handler: parse callInvitation.links.acceptance from the attach response, then
 * POST the accept (our SDP answer). */
static void
attach_resp_cb(PurpleHttpConnection *hc, PurpleHttpResponse *resp, gpointer u)
{
	TeamsCall *call = (TeamsCall *) u;
	int code; const gchar *data; size_t len = 0;
	JsonObject *root, *ci, *links; const gchar *acc = NULL;
	(void) hc;
	code = purple_http_response_get_code(resp);
	data = purple_http_response_get_data(resp, &len);
	teams_call_log("attach resp code=%d (%d bytes)", code, (int) len);
	if (code < 200 || code >= 300 || !data) {
		teams_call_log("attach FAILED: %.240s", data ? data : "(no body)");
		return;
	}
	root = json_decode_object(data, len);
	if (root && (ci = oget(root, "callInvitation")) && (links = oget(ci, "links")))
		acc = sget(links, "acceptance");
	if (acc) {
		gchar *acc_dup = g_strdup(acc);
		teams_call_log("attach OK -> acceptance link acquired, posting accept");
		teams_calling_post_accept(call, acc_dup);
		g_free(acc_dup);
	} else {
		teams_call_log("attach OK but no callInvitation.links.acceptance in response");
	}
	if (root) json_object_unref(root);
}

/* Incoming answer = two-step media-controller handshake (see media_send_answer). Step 1 here:
 * POST attach to the offer's link_attach; the response yields the acceptance link (step 2). */
static void
teams_calling_post_answer(TeamsCall *call, const char *answer_sdp)
{
	const char *agent;
	gchar *end_link, *body;
	(void) answer_sdp;   /* already stored on call->our_answer_sdp; posted in step 2 */
	if (!call->link_attach) { teams_call_log("post_answer: no attach link"); return; }

	/* generate our endpoint/participant/callAgent identity for this call (reused in accept) */
	if (!call->our_endpoint_id)    call->our_endpoint_id = g_strdup(call->sa->endpoint ? call->sa->endpoint : "");
	if (!call->our_participant_id) call->our_participant_id = purple_uuid_random();
	if (!call->callagent_id)       call->callagent_id = purple_uuid_random();
	agent = call->callagent_id;
	end_link = callagent_path(call, agent, "call", "end");

	body = g_strdup_printf(
		"{\"attach\":{\"requireMediaContent\":false,\"links\":{\"end\":\"%s\"},"
		  "\"locationContent\":null,\"networkContent\":null,\"areaContent\":null,"
		  "\"applicationType\":\"TFL\"},"
		"\"capabilities\":null,\"endpointCapabilities\":73463}",
		end_link);
	teams_call_log("post_answer: attach (step 1/2) -> %d-byte body", (int) strlen(body));
	flightproxy_post_cb(call->sa, call->link_attach, body, attach_resp_cb, call);
	g_free(end_link); g_free(body);
}

/* ------------------------------------------------------------------ TeamsCall */

static const char *
state_str(TeamsCallState s)
{
	switch (s) {
		case TEAMS_CALL_INCOMING:     return "incoming";
		case TEAMS_CALL_DIALING:      return "dialing";
		case TEAMS_CALL_ACTIVE:       return "active";
		case TEAMS_CALL_DISCONNECTED: return "disconnected";
		default:                      return ""; /* idle */
	}
}

static void
push_state(TeamsCall *call, const char *cause)
{
	if (!g_state_cb || !call) return;
	g_state_cb(call->sa, state_str(call->state),
	           call->peer_mri ? teams_strip_user_prefix(call->peer_mri) : NULL,
	           call->peer_name, call->is_outgoing, cause);
}

static void
teams_call_free(TeamsCall *call)
{
	if (!call) return;
	g_free(call->call_id);
	g_free(call->peer_mri);
	g_free(call->peer_name);
	g_free(call->sdp_offer);
	g_free(call->media_leg_id);
	g_free(call->session_key_b64);
	g_free(call->ticket);
	g_free(call->link_attach);
	g_free(call->link_media_answer);
	g_free(call->link_progress);
	g_free(call->link_reject);
	g_free(call->udp_transport);
	g_free(call->conversation_controller);
	g_free(call->our_answer_sdp);
	g_free(call->our_endpoint_id);
	g_free(call->our_participant_id);
	g_free(call->callagent_id);
	g_free(call);
}

TeamsCall *
teams_calling_current(TeamsAccount *sa)
{
	return sa ? (TeamsCall *) sa->active_call : NULL;
}

static void
set_current(TeamsAccount *sa, TeamsCall *call)
{
	TeamsCall *old = (TeamsCall *) sa->active_call;
	if (old && old != call) teams_call_free(old);
	sa->active_call = call;
}

/* ------------------------------------------------------------------- capture */

/* Append the full raw notification (pretty-printed) plus a decoded summary to the capture
 * log. This is the single most important output of the initial drop: it lets us confirm
 * the exact sdp-ngc dialect, the codec/payload list, and whether the SRTP key rides in the
 * SDP a=crypto line or only in udpKey.sessionKey - none of which are documented. */
static void
capture_notification(TeamsAccount *sa, JsonObject *body_obj, const gchar *request_url)
{
	FILE *f = fopen(TEAMS_CALL_CAPTURE, "a");
	gchar *pretty;
	time_t now = time(NULL);
	char ts[32];
	struct tm *tm = localtime(&now);
	strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);

	if (!f) return;
	pretty = teams_jsonobj_to_string(body_obj); /* pretty JSON */
	fprintf(f, "\n===== %s  url=%s  account=%s =====\n", ts, request_url ? request_url : "?",
	        sa && sa->username ? sa->username : "?");
	if (pretty) {
		fputs(pretty, f);
		fputc('\n', f);
		g_free(pretty);
	}
	fclose(f);
}

/* --------------------------------------------------------------- parse offer */

static TeamsCall *
parse_call_notification(TeamsAccount *sa, JsonObject *body_obj)
{
	JsonObject *cn = oget(body_obj, "callNotification");
	JsonObject *from, *to, *links, *media, *udpKey, *convInv, *debug;
	const gchar *fromId, *toId;
	TeamsCall *call;

	if (!cn) return NULL;

	from   = oget(cn, "from");
	to     = oget(cn, "to");
	links  = oget(cn, "links");
	media  = oget(cn, "mediaContent");
	udpKey = oget(cn, "udpKey");
	convInv = oget(body_obj, "conversationInvitation");
	debug  = oget(body_obj, "debugContent");

	fromId = from ? sget(from, "id") : NULL;
	toId   = to ? sget(to, "id") : NULL;

	call = g_new0(TeamsCall, 1);
	call->sa = sa;

	/* incoming vs outgoing: if WE are the caller it's an outgoing call notification (a fork
	 * / carbon of our own placed call), and the peer is the callee. */
	if (fromId && teams_is_user_self(sa, fromId)) {
		call->is_outgoing = TRUE;
		call->peer_mri  = g_strdup(toId);
		call->peer_name = g_strdup(to ? sget(to, "displayName") : NULL);
	} else {
		call->is_outgoing = FALSE;
		call->peer_mri  = g_strdup(fromId);
		call->peer_name = g_strdup(from ? sget(from, "displayName") : NULL);
	}

	if (debug)  call->call_id = g_strdup(sget(debug, "callId"));

	if (media) {
		call->sdp_offer    = g_strdup(sget(media, "blob"));
		call->media_leg_id = g_strdup(sget(media, "mediaLegId"));
	}
	if (udpKey) {
		call->session_key_b64 = g_strdup(sget(udpKey, "sessionKey"));
		call->ticket          = g_strdup(sget(udpKey, "ticket"));
	}
	if (links) {
		call->link_attach       = g_strdup(sget(links, "attach"));
		call->link_media_answer = g_strdup(sget(links, "mediaAnswer"));
		call->link_progress     = g_strdup(sget(links, "progress"));
		call->link_reject       = g_strdup(sget(links, "reject"));
		call->udp_transport     = g_strdup(sget(links, "udpTransport"));
	}
	if (convInv)
		call->conversation_controller = g_strdup(sget(convInv, "conversationController"));

	return call;
}

/* --------------------------------------------------------------- HTTP control */

/* POST (empty or small body) to a full https URL from the notification's links. Splits the
 * URL into host + path for teams_post_or_get. Auth headers are added by teams_post_or_get
 * for skype/teams hosts; CONFIRM WITH CAPTURE that flightproxy accepts the same token. */
static void
call_http_post(TeamsAccount *sa, const gchar *full_url, const gchar *body)
{
	const gchar *p;
	gchar *host, *path;
	const gchar *slash;

	if (!full_url) return;
	if (g_str_has_prefix(full_url, "https://")) p = full_url + 8;
	else if (g_str_has_prefix(full_url, "http://")) p = full_url + 7;
	else { teams_call_log("http_post: non-http link '%s' (skipped)", full_url); return; }

	slash = strchr(p, '/');
	if (slash) {
		host = g_strndup(p, slash - p);
		path = g_strdup(slash);
	} else {
		host = g_strdup(p);
		path = g_strdup("/");
	}
	teams_call_log("http_post host=%s path=%.80s body=%d bytes", host, path, body ? (int) strlen(body) : 0);
	teams_post_or_get(sa, TEAMS_METHOD_POST | TEAMS_METHOD_SSL, host, path, body, NULL, NULL, FALSE);
	g_free(host);
	g_free(path);
}

/* --------------------------------------------------------------- trouter entry */

/* DEBUG auto-answer timer: answer the current incoming call (see the toggle in handle_trouter). */
static gboolean
teams_calling_autoanswer_cb(gpointer user)
{
	TeamsAccount *sa = user;
	teams_call_log("AUTO-ANSWER firing");
	teams_calling_answer(sa);
	return G_SOURCE_REMOVE;
}

/* Outgoing call: the callee accepted and Teams delivered their SDP answer on our callAgent
 * mediaAnswer link. Extract ice-ufrag/pwd + the a=crypto RX key + candidates, and feed them to the
 * caller media engine (ANSWER + RCAND) so it applies the peer's key, sets remote creds and connects
 * ICE. The exact frame shape isn't fully known yet, so probe a few likely blob locations. */
static void
teams_calling_handle_media_answer(TeamsAccount *sa, JsonObject *body_obj)
{
	TeamsCall *call = teams_calling_current(sa);
	TeamsMediaProc *mp = g_mproc;
	JsonObject *mc = NULL, *sub;
	const gchar *blob = NULL;
	gchar *ruf, *rpw, *rxkey, **lines; int i;

	if (!call || !mp || !mp->is_caller || mp->in_fd < 0) {
		teams_call_log("mediaAnswer: no outgoing caller engine to apply it to"); return;
	}
	if ((mc = oget(body_obj, "mediaContent")))            blob = sget(mc, "blob");
	if (!blob && (sub = oget(body_obj, "mediaAnswer")) && (mc = oget(sub, "mediaContent"))) blob = sget(mc, "blob");
	if (!blob && (sub = oget(body_obj, "callNotification")) && (mc = oget(sub, "mediaContent"))) blob = sget(mc, "blob");
	if (!blob) { teams_call_log("mediaAnswer: no SDP blob found (see capture log for shape)"); return; }

	ruf = sdp_line_val(blob, "a=ice-ufrag:");
	rpw = sdp_line_val(blob, "a=ice-pwd:");
	rxkey = sdp_gcm_key(blob);
	if (!ruf || !rpw || !rxkey) {
		teams_call_log("mediaAnswer: answer missing ice/crypto (uf=%d pw=%d key=%d)",
		               ruf != NULL, rpw != NULL, rxkey != NULL);
		g_free(ruf); g_free(rpw); g_free(rxkey); return;
	}
	teams_call_log("mediaAnswer: applying peer answer -> ANSWER + RCAND to caller engine");
	{ gchar *s = g_strdup_printf("ANSWER %s %s %s\n", rxkey, ruf, rpw);
	  if (write(mp->in_fd, s, strlen(s)) < 0) {} g_free(s); }
	lines = g_strsplit(blob, "\n", -1);
	for (i = 0; lines[i]; i++) {
		gchar *l = g_strstrip(lines[i]);
		if (g_str_has_prefix(l, "a=candidate:")) {
			gchar *r = g_strdup_printf("RCAND %s\n", l + 2);
			if (write(mp->in_fd, r, strlen(r)) < 0) {} g_free(r);
		}
	}
	g_strfreev(lines);
	call->state = TEAMS_CALL_ACTIVE;
	push_state(call, NULL);
	g_free(ruf); g_free(rpw); g_free(rxkey);
}

void
teams_calling_handle_trouter(TeamsAccount *sa, JsonObject *body_obj, const gchar *request_url)
{
	/* Always capture first - even notifications we don't yet model are ground truth. */
	capture_notification(sa, body_obj, request_url);

	if (request_url && strstr(request_url, "callAgent/"))
		teams_call_log("callAgent frame: %s", strstr(request_url, "callAgent/"));

	/* Outgoing call: callee is ringing (progress) or has answered (mediaAnswer). */
	if (request_url && (strstr(request_url, "/mediaAnswer") || strstr(request_url, "/mediaanswer"))) {
		teams_call_log("outgoing: MEDIA ANSWER frame received");
		teams_calling_handle_media_answer(sa, body_obj);
		return;
	}
	if (request_url && strstr(request_url, "/progress")) {
		TeamsCall *call = teams_calling_current(sa);
		teams_call_log("outgoing: PROGRESS frame (callee ringing)");
		if (call) push_state(call, "ringing");
		return;
	}

	/* Call ended */
	if (request_url && (strstr(request_url, "/call/end") || g_str_has_suffix(request_url, "/end")
	                    || g_str_has_suffix(request_url, "/end/"))) {
		TeamsCall *call = teams_calling_current(sa);
		if (call) {
			JsonObject *ce = oget(body_obj, "callEnd");
			const gchar *phrase = ce ? sget(ce, "phrase") : NULL;
			call->state = TEAMS_CALL_DISCONNECTED;
			teams_call_log("call ended: %s", phrase ? phrase : "(no reason)");
			push_state(call, phrase ? phrase : "normal");
			teams_media_stop();
			set_current(sa, NULL);
		}
		return;
	}

	/* Roster update mid-call - not modeled yet, capture only. */
	if (request_url && g_str_has_suffix(request_url, "/rosterUpdate"))
		return;

	/* Incoming/outgoing call setup (callNotification present). */
	if (json_object_has_member(body_obj, "callNotification")) {
		TeamsCall *call = parse_call_notification(sa, body_obj);
		if (!call) return;

		call->state = call->is_outgoing ? TEAMS_CALL_DIALING : TEAMS_CALL_INCOMING;
		set_current(sa, call);

		teams_call_log("%s call  peer=%s (%s)  sdp=%d bytes  key=%s  ticket=%s  relay=%s  reject=%s",
		               call->is_outgoing ? "OUTGOING" : "INCOMING",
		               call->peer_mri ? call->peer_mri : "?",
		               call->peer_name ? call->peer_name : "?",
		               call->sdp_offer ? (int) strlen(call->sdp_offer) : 0,
		               call->session_key_b64 ? "yes" : "no",
		               call->ticket ? "yes" : "no",
		               call->udp_transport ? call->udp_transport : "?",
		               call->link_reject ? "yes" : "no");

		/* Ring the Phone app (incoming) / show dialing (outgoing carbon). */
		push_state(call, NULL);

		/* DEBUG auto-answer: if /media/internal/teams-autoanswer exists, answer an INCOMING call
		 * automatically after 3s. Lets the media path be tested by just placing a call (no physical
		 * tap on the device). Toggle by creating/removing the file; no rebuild needed. */
		if (!call->is_outgoing && g_file_test("/media/internal/teams-autoanswer", G_FILE_TEST_EXISTS)) {
			teams_call_log("AUTO-ANSWER armed (toggle present) - answering in 3s");
			g_timeout_add_seconds(3, teams_calling_autoanswer_cb, sa);
		}
		return;
	}
}

/* --------------------------------------------------------------- actions (LS2) */

gboolean
teams_calling_answer(TeamsAccount *sa)
{
	TeamsCall *call = teams_calling_current(sa);
	if (!call || call->state != TEAMS_CALL_INCOMING) {
		teams_call_log("answer: no incoming call");
		return FALSE;
	}
	teams_call_log("answer: starting media for call with %s", call->peer_mri ? call->peer_mri : "?");

	/* Start the media engine. It will (once wired) allocate on the MS-TURN relay with the
	 * ticket, set up SRTP from sessionKey, negotiate the offered codec, and hand back an
	 * SDP answer. That answer then gets POSTed to link_media_answer/attach. For now the
	 * media start is a stub, so we only transition state so the flow is exercisable. */
	teams_media_start(call);

	/* TODO(capture): POST the produced SDP answer to call->link_media_answer ("cc://ma" is
	 * an alias resolved via link_attach on api.flightproxy...). Exact body shape =
	 * { "mediaContent": { "contentType": "application/sdp-ngc-0.5", "blob": <answer>,
	 *   "mediaLegId": <call->media_leg_id> } } - CONFIRM WITH CAPTURE. */

	call->state = TEAMS_CALL_ACTIVE;
	push_state(call, NULL);
	return TRUE;
}

gboolean
teams_calling_reject(TeamsAccount *sa)
{
	TeamsCall *call = teams_calling_current(sa);
	if (!call) { teams_call_log("reject: no call"); return FALSE; }
	teams_call_log("reject: rejecting call from %s", call->peer_mri ? call->peer_mri : "?");

	if (call->link_reject)
		call_http_post(sa, call->link_reject, NULL); /* reject is a bare POST, no body */

	call->state = TEAMS_CALL_DISCONNECTED;
	push_state(call, "rejected");
	teams_media_stop();
	set_current(sa, NULL);
	return TRUE;
}

gboolean
teams_calling_hangup(TeamsAccount *sa)
{
	TeamsCall *call = teams_calling_current(sa);
	if (!call) { teams_call_log("hangup: no call"); return FALSE; }
	teams_call_log("hangup: ending call with %s", call->peer_mri ? call->peer_mri : "?");

	/* An active call is ended via the conversation controller; a still-ringing incoming
	 * call is declined via link_reject. CONFIRM WITH CAPTURE the exact end/hangup shape. */
	if (call->state == TEAMS_CALL_INCOMING && call->link_reject)
		call_http_post(sa, call->link_reject, NULL);

	call->state = TEAMS_CALL_DISCONNECTED;
	push_state(call, "normal");
	teams_media_stop();
	set_current(sa, NULL);
	return TRUE;
}

gboolean
teams_calling_dial(TeamsAccount *sa, const gchar *peer_mri)
{
	/* Outgoing (caller): spawn teams_media --caller to gather our ICE + generate the offer's SRTP
	 * key, then media_send_offer() builds the SDP offer and POSTs the cpconv create request (which
	 * makes the peer ring). The answer comes back over the trouter callAgent path. FIRST-ATTEMPT. */
	TeamsCall *call;
	TeamsMediaProc *mp;
	const gchar *argv[] = { TEAMS_MEDIA_BIN, "--caller", NULL };
	const gchar *W = "/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/lib";
	gchar *gstpath = g_strdup_printf("%s/gstreamer-1.0", W);
	gchar **envp = g_get_environ();
	GError *err = NULL;
	GPid pid; int in_fd = -1, out_fd = -1;

	if (!sa->trouter_surl) { teams_call_log("dial: no trouter surl - cannot place call"); g_strfreev(envp); g_free(gstpath); return FALSE; }

	envp = g_environ_setenv(envp, "GST_PLUGIN_SYSTEM_PATH_1_0", gstpath, TRUE);
	envp = g_environ_setenv(envp, "GST_REGISTRY", "/media/internal/teams-gst-registry.bin", TRUE);
	g_free(gstpath);

	if (!g_spawn_async_with_pipes(NULL, (gchar **) argv, envp, G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL,
	                              &pid, &in_fd, &out_fd, NULL, &err)) {
		teams_call_log("dial: spawn %s --caller failed: %s", TEAMS_MEDIA_BIN, err ? err->message : "?");
		if (err) g_error_free(err); g_strfreev(envp); return FALSE;
	}
	g_strfreev(envp);

	call = g_new0(TeamsCall, 1);
	call->sa = sa;
	call->is_outgoing = TRUE;
	call->state = TEAMS_CALL_DIALING;
	call->peer_mri = g_str_has_prefix(peer_mri, "8:") ? g_strdup(peer_mri) : g_strdup_printf("8:%s", peer_mri);
	set_current(sa, call);

	mp = g_new0(TeamsMediaProc, 1);
	mp->call = call; mp->pid = pid; mp->in_fd = in_fd; mp->is_caller = TRUE;
	mp->callagent_id = purple_uuid_random();
	mp->our_cands = g_string_new("");
	mp->out_ch = g_io_channel_unix_new(out_fd);
	g_io_channel_set_flags(mp->out_ch, G_IO_FLAG_NONBLOCK, NULL);
	mp->out_watch = g_io_add_watch(mp->out_ch, G_IO_IN | G_IO_HUP | G_IO_ERR, media_on_output, mp);
	g_mproc = mp;

	/* CALLER START: no rx key (we produce the offer). pt=102 for opus. */
	{ const char *s = "START 102\n"; if (write(in_fd, s, strlen(s)) < 0) teams_call_log("dial: write START failed"); }

	teams_call_log("dial: spawned teams_media --caller pid=%d, calling %s (callAgent=%s)",
	               (int) pid, call->peer_mri, mp->callagent_id);
	push_state(call, NULL);   /* dialing */
	return TRUE;
}
