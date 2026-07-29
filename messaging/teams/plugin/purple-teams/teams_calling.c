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

/* Media engine plug point. The real engine (teams_media - a fork of Signal's on-device
 * gst-1.20 nice+srtp+alsa engine) runs out-of-process and is driven over an IPC line
 * protocol. Until it is wired (pending a live capture to confirm codec + MS-TURN auth),
 * these are traced stubs so the signaling + bridge can be exercised end-to-end. */
static void
teams_media_start(TeamsCall *call)
{
	teams_call_log("MEDIA start (STUB - engine wiring pending capture): relay=%s legId=%s "
	               "sessionKey=%d b64-chars ticket=%s sdp=%d bytes",
	               call->udp_transport ? call->udp_transport : "(none)",
	               call->media_leg_id ? call->media_leg_id : "(none)",
	               call->session_key_b64 ? (int) strlen(call->session_key_b64) : 0,
	               call->ticket ? "present" : "(none)",
	               call->sdp_offer ? (int) strlen(call->sdp_offer) : 0);
}

static void
teams_media_stop(void)
{
	teams_call_log("MEDIA stop (STUB)");
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

void
teams_calling_handle_trouter(TeamsAccount *sa, JsonObject *body_obj, const gchar *request_url)
{
	/* Always capture first - even notifications we don't yet model are ground truth. */
	capture_notification(sa, body_obj, request_url);

	/* Call ended */
	if (request_url && g_str_has_suffix(request_url, "/end")) {
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
	/* Placing an outgoing call requires the NGC call-create flow (POST to a conversation
	 * controller with our SDP offer), which is NOT in the reverse-engineered notification
	 * data - it needs an OUTGOING-call capture to model. Documented stub for now. */
	teams_call_log("dial: outgoing call to %s requested - NOT YET IMPLEMENTED "
	               "(needs an outgoing-call capture to model the NGC create flow)",
	               peer_mri ? peer_mri : "?");
	return FALSE;
}
