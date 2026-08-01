/*
 * Teams NGC calling - webOS LS2 bridge (com.palm.teams.call). See teams_call_luna.h.
 * Ported from the Telegram call-luna.cpp mediator, in C, driving teams_calling.c.
 */

#include "teams_call_luna.h"
#include "teams_calling.h"
#include "skypekit.h"
#include "teams_video_relay.h"

#include <lunaservice.h>
#include <glib.h>
#include <string.h>

/* One service per process (whichever Teams account logs in first owns it). */
static LSPalmService *g_service = NULL;
static LSHandle      *g_pub     = NULL;
static LSHandle      *g_prv     = NULL;
static GMainLoop     *g_loopRef = NULL;
static TeamsAccount  *g_sa      = NULL;

/* Last state pushed, so a late subscriber gets the current picture in its first reply. */
static gchar   *g_state    = NULL;
static gchar   *g_peerAddr = NULL;
static gchar   *g_peerName = NULL;
static gchar   *g_cause    = NULL;
static gboolean g_outgoing = FALSE;

/* Native SkypeKit video bridge state (see the clonk lifecycle functions near the end of this
 * file). g_clonkUri = the open clonk session's palm:// LS2 URI, if any; g_videoActive mirrors
 * whether that session/bridge is currently up. */
static gchar   *g_clonkUri    = NULL;
static gboolean g_videoActive = FALSE;

#define SUBKEY "callState"

static void
setstr(gchar **slot, const char *v)
{
	g_free(*slot);
	*slot = g_strdup(v ? v : "");
}

/* Build the CallSynergizer callStateQuery payload. Fields MUST be flat (address/displayName
 * directly on each call - CallSynergyContact.create() throws if address is missing) and carry
 * transport = this mediator's PHONE account templateId ("com.palm.teams") so the Phone app
 * treats it as the IM call it is, not a cellular number. Mirrors the Telegram mediator. */
static gchar *
build_payload(void)
{
	GString *p = g_string_new("{\"returnValue\":true,\"allowVideoCalls\":true,\"videoURI\":\"");
	if (g_clonkUri) {
		gchar *uri = g_strescape(g_clonkUri, "");
		g_string_append(p, uri);
		g_free(uri);
	}
	g_string_append(p, "\",\"lines\":[");
	if (g_state && *g_state) {
		gchar *addr = g_strescape(g_peerAddr ? g_peerAddr : "", "");
		gchar *name = g_strescape((g_peerName && *g_peerName) ? g_peerName : (g_peerAddr ? g_peerAddr : ""), "");
		gchar *cause = g_strescape(g_cause ? g_cause : "", "");

		g_string_append_printf(p, "{\"state\":\"%s\",", g_state);
		if (g_strcmp0(g_state, "disconnected") == 0)
			g_string_append_printf(p, "\"disconnectDetails\":{\"cause\":\"%s\"},", cause);
		g_string_append_printf(p,
			"\"calls\":[{\"id\":\"teams\",\"origin\":\"%s\",\"video\":%s,"
			"\"transport\":\"com.palm.teams\",\"address\":\"%s\",\"displayName\":\"%s\"}]}",
			g_outgoing ? "outgoing" : "incoming", g_videoActive ? "true" : "false", addr, name);
		g_free(addr); g_free(name); g_free(cause);
	}
	g_string_append(p, "]}");
	return g_string_free(p, FALSE);
}

/* tiny top-level string field extractor (avoids a JSON dep) */
static gchar *
get_field(const char *json, const char *key)
{
	gchar *needle, *ret = NULL;
	const char *k, *c, *e;
	if (!json) return NULL;
	needle = g_strdup_printf("\"%s\"", key);
	k = strstr(json, needle);
	if (k) {
		c = strchr(k + strlen(needle), ':');
		if (c) {
			while (*++c == ' ') ;
			if (*c == '"') {
				e = strchr(++c, '"');
				if (e) ret = g_strndup(c, e - c);
			}
		}
	}
	g_free(needle);
	return ret;
}

/* tiny top-level bool field extractor, mirrors get_field() above */
static gboolean
get_bool_field(const char *json, const char *key)
{
	gchar *needle; const char *k, *c; gboolean ret = FALSE;
	if (!json) return FALSE;
	needle = g_strdup_printf("\"%s\"", key);
	k = strstr(json, needle);
	if (k) {
		c = strchr(k + strlen(needle), ':');
		if (c) {
			while (*++c == ' ') ;
			ret = (strncmp(c, "true", 4) == 0);
		}
	}
	g_free(needle);
	return ret;
}

/* ------------------------------------------------------------------- methods */

static bool
cb_call_state_query(LSHandle *sh, LSMessage *msg, void *ctx)
{
	LSError err; bool subscribed = FALSE; gchar *payload;
	(void) ctx;
	LSErrorInit(&err);
	LSSubscriptionProcess(sh, msg, &subscribed, &err);
	if (subscribed)
		LSSubscriptionAdd(sh, SUBKEY, msg, &err);
	payload = build_payload();
	LSMessageReply(sh, msg, payload, &err);
	g_free(payload);
	if (LSErrorIsSet(&err)) { purple_debug_warning("teams", "callStateQuery: %s\n", err.message); LSErrorFree(&err); }
	return TRUE;
}

static bool
cb_dial(LSHandle *sh, LSMessage *msg, void *ctx)
{
	LSError err; gchar *addr; gboolean video, ok;
	const char *payload = LSMessageGetPayload(msg);
	(void) ctx;
	LSErrorInit(&err);
	addr = get_field(payload, "address");
	video = get_bool_field(payload, "video");
	ok = g_sa && addr && *addr && teams_calling_dial(g_sa, addr, video);
	teams_call_log("cbDial addr=%s video=%d ok=%d", addr ? addr : "(null)", (int) video, (int) ok);
	LSMessageReply(sh, msg, ok ? "{\"returnValue\":true}" : "{\"returnValue\":false}", &err);
	g_free(addr);
	if (LSErrorIsSet(&err)) LSErrorFree(&err);
	return TRUE;
}

static bool
cb_answer(LSHandle *sh, LSMessage *msg, void *ctx)
{
	LSError err; (void) ctx;
	LSErrorInit(&err);
	if (g_sa) teams_calling_answer(g_sa);
	LSMessageReply(sh, msg, "{\"returnValue\":true}", &err);
	if (LSErrorIsSet(&err)) LSErrorFree(&err);
	return TRUE;
}

static bool
cb_disconnect(LSHandle *sh, LSMessage *msg, void *ctx)
{
	LSError err; (void) ctx;
	LSErrorInit(&err);
	if (g_sa) teams_calling_hangup(g_sa);
	LSMessageReply(sh, msg, "{\"returnValue\":true}", &err);
	if (LSErrorIsSet(&err)) LSErrorFree(&err);
	return TRUE;
}

static bool
cb_noop(LSHandle *sh, LSMessage *msg, void *ctx)
{
	LSError err; (void) ctx;
	LSErrorInit(&err);
	LSMessageReply(sh, msg, "{\"returnValue\":true}", &err);
	if (LSErrorIsSet(&err)) LSErrorFree(&err);
	return TRUE;
}

static LSMethod g_methods[] = {
	{ "callStateQuery",  cb_call_state_query },
	{ "dial",            cb_dial             },
	{ "answer",          cb_answer           },
	{ "disconnect",      cb_disconnect       },
	{ "hangupAll",       cb_disconnect       },
	{ "hangupAllActive", cb_disconnect       },
	{ "hold",            cb_noop             },
	{ "swap",            cb_noop             },
	{ "merge",           cb_noop             },
	{ "extract",         cb_noop             },
	{ "dtmf",            cb_noop             },
	{ "dtmfEnd",         cb_noop             },
	{ "changeMedia",     cb_noop             },
	{ NULL, NULL }
};

/* ------------------------------------------------------------- state push in */

static void push_to(LSHandle *h, const char *payload)
{
	LSError err;
	if (!h) return;
	LSErrorInit(&err);
	LSSubscriptionReply(h, SUBKEY, payload, &err);
	if (LSErrorIsSet(&err)) { purple_debug_warning("teams", "pushState: %s\n", err.message); LSErrorFree(&err); }
}

/* teams_calling state callback: cache + push to both connections (public = untrusted apps,
 * private = the stock Phone app), and drive call audio on active/idle. */
static void
on_call_state(TeamsAccount *sa, const char *state, const char *peerAddress,
              const char *peerName, gboolean isOutgoing, const char *cause)
{
	gchar *payload;
	(void) sa;
	setstr(&g_state, state);
	setstr(&g_peerAddr, peerAddress);
	setstr(&g_peerName, peerName);
	setstr(&g_cause, cause);
	g_outgoing = isOutgoing;
	teams_call_log("pushState state=%s addr=%s pub=%p prv=%p", g_state, g_peerAddr, (void*)g_pub, (void*)g_prv);

	if (g_strcmp0(g_state, "active") == 0)      teams_call_luna_set_audio(TRUE);
	else if (!g_state || !*g_state || g_strcmp0(g_state, "disconnected") == 0) teams_call_luna_set_audio(FALSE);

	if (!g_pub && !g_prv) return;
	payload = build_payload();
	push_to(g_pub, payload);
	push_to(g_prv, payload);
	g_free(payload);
}

/* --------------------------------------------------------------- init/shutdown */

static void on_video_active_changed(TeamsAccount *sa, gboolean active);

gboolean
teams_call_luna_init(TeamsAccount *sa)
{
	LSError err;
	g_sa = sa;
	teams_calling_set_state_cb(on_call_state);
	teams_calling_set_video_cb(on_video_active_changed);
	teams_call_log("teams_call_luna_init account=%s service=%p",
	               sa && sa->username ? sa->username : "(null)", (void*)g_service);
	if (g_service) return TRUE;   /* already registered */

	LSErrorInit(&err);
	if (!LSRegisterPalmService("com.palm.teams.call", &g_service, &err)) {
		teams_call_log("LSRegisterPalmService FAIL: %s", err.message);
		LSErrorFree(&err); return FALSE;
	}
	if (!LSPalmServiceRegisterCategory(g_service, "/", g_methods, g_methods, NULL, NULL, &err)) {
		teams_call_log("RegisterCategory FAIL: %s", err.message);
		LSErrorFree(&err); return FALSE;
	}
	g_loopRef = g_main_loop_new(g_main_context_default(), FALSE);
	if (!LSGmainAttachPalmService(g_service, g_loopRef, &err)) {
		teams_call_log("GmainAttach FAIL: %s", err.message);
		LSErrorFree(&err); return FALSE;
	}
	g_pub = LSPalmServiceGetPublicConnection(g_service);
	g_prv = LSPalmServiceGetPrivateConnection(g_service);
	teams_call_log("com.palm.teams.call REGISTERED pub=%p prv=%p", (void*)g_pub, (void*)g_prv);
	return TRUE;
}

void
teams_call_luna_shutdown(TeamsAccount *sa)
{
	if (g_sa == sa) g_sa = NULL;
}

/* --------------------------------------------------------------- call audio */

static bool audiod_reply(LSHandle *sh, LSMessage *m, void *ctx) { (void)sh;(void)m;(void)ctx; return TRUE; }

static void
audiod_send(const char *uri, const char *payload)
{
	LSError err; LSMessageToken tok;
	if (!g_prv) return;
	LSErrorInit(&err);
	if (!LSCallOneReply(g_prv, uri, payload, audiod_reply, NULL, &tok, &err)) {
		purple_debug_warning("teams", "audiod %s: %s\n", uri, err.message);
		LSErrorFree(&err);
	}
}

void
teams_call_luna_set_audio(gboolean active)
{
	teams_call_log("set_audio active=%d prv=%p", (int) active, (void*)g_prv);
	/* NOTE: teams_media routes call audio through the Atlas qspkd/qmicd daemons (media speaker + mic),
	 * NOT the pvoip phone path - because the new-glibc wpe-gst engine can't reach PulseAudio's pvoip.
	 * We deliberately do NOT call setCurrentScenario("phone_back_speaker") - that scenario suppresses
	 * qspkd's media-speaker output (verified: a qspk tone goes silent under it), breaking RX playback.
	 *
	 * BUT we DO send a CallStatusUpdate "kick" here - reverse-engineered finding (Ghidra decompile of
	 * /usr/sbin/audiod, cross-checked against github.com/webosose/audiod-pro's State::setCallMode /
	 * TopazDevice::updateCallMode, which share the same class layout): TopazDevice::updateCallMode()'s
	 * VoIP route-switch block (the msm_en_device/msm_capture_route/UCM device-set calls that actually
	 * (re)power the mic/speaker route) is gated behind a "loopback armed" flag that's ONLY set by a
	 * prior CARRIER-mode CallStatusUpdate - and only CONSUMED (never re-armed) by the next VoIP one.
	 * On a Wi-Fi-only device with no real carrier, that flag is armed at most once per audiod process
	 * lifetime, so only the FIRST VoIP call each audiod session actually re-inits mic/speaker hardware
	 * routing; every call after that silently no-ops (matches the long-standing "mic/audio randomly
	 * stops, reboot fixes it" pattern). Sending a synthetic transport="com.palm.telephony" (Carrier)
	 * CallStatusUpdate immediately before the real one re-arms that flag every time, forcing a genuine
	 * route re-init on every call. This does NOT invoke setCurrentScenario (confirmed in the decompile:
	 * that's only called when the CURRENT scenario is already bluetooth_sco), so it should not disturb
	 * qspkd's routing. See webos-audiod-re/ for the full writeup + decompiled/reconstructed source. */
	if (active) {
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate",
		            "{\"lines\":[{\"state\":\"active\",\"calls\":[{\"id\":\"kick\",\"transport\":\"com.palm.telephony\"}]}]}");
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate",
		            "{\"lines\":[{\"state\":\"active\",\"calls\":[{\"id\":\"1\",\"transport\":\"com.palm.teams\"}]}]}");
	} else {
		/* a bare {"lines":[]} skips _callStatusUpdate's per-line loop entirely (0 lines -> State::
		 * setCallMode is never called at all) - send a real "disconnected" line so State's own
		 * bookkeeping (mNumVoip, mCallMode) stays consistent, even though the known audiod bug means
		 * this alone won't re-sync TopazDevice's cached mode (updateCallMode() isn't called here). */
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate",
		            "{\"lines\":[{\"state\":\"disconnected\",\"calls\":[{\"id\":\"1\",\"transport\":\"com.palm.teams\"}]}]}");
	}
}

/* --------------------------------------------------------------- video (clonk bridge) */
/* Native SkypeKit H.264 video bridge, ported from Telegram's call-luna.cpp clonk chain (see that
 * file + messaging/whatsapp/calling/WHATSAPP_VIDEO_STATUS.md Parts 1-21 for the full
 * reverse-engineering trail this mirrors) - skypekit.cpp/h264_rtp.c/teams_video_relay.cpp now link
 * directly into THIS process (libteams-personal.so), same as Telegram, so the sequencing is
 * identical to Telegram's: skypekit_video_start() blocks, teams_video_relay_connect() hooks it up
 * to teams_media's raw-RTP relay socket, then videoPlayerStart fires immediately after (Thread A is
 * now bound+listening - WHATSAPP_VIDEO_STATUS.md Part 17: mediaserver won't dial the outbound
 * socket until the inbound one has an accepted peer). The network RTP/SRTP/ICE transport itself
 * still lives in the separate teams_media subprocess - see teams_media.c's top-of-file comment for
 * why that split is necessary. */

static bool clonk_capture_start_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx);
static bool clonk_player_start_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx);
static bool clonk_keyframe_start_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx);

static void
clonk_uri_call(const char *method, const char *json_payload, LSFilterFunc cb, void *ctx)
{
	LSError err; LSMessageToken tok; gchar *uri;
	if (!g_prv || !g_clonkUri) return;
	LSErrorInit(&err);
	uri = g_strdup_printf("%s%s", g_clonkUri, method);
	if (!LSCallOneReply(g_prv, uri, json_payload, cb, ctx, &tok, &err)) {
		teams_call_log("clonk %s call failed: %s", method, err.message);
		LSErrorFree(&err);
	}
	g_free(uri);
}

static bool
clonk_capture_start_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx)
{
	(void) sh; (void) ctx;
	teams_call_log("clonk videoCaptureStart: %s", LSMessageGetPayload(msg));
	skypekit_video_start();
	if (!teams_video_relay_connect())
		teams_call_log("video relay connect failed (is teams_media up?) - continuing anyway");
	clonk_uri_call("videoPlayerStart", "{\"args\":[320,240]}", clonk_player_start_reply_cb, NULL);
	return TRUE;
}

static bool
clonk_player_start_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx)
{
	(void) sh; (void) ctx;
	teams_call_log("clonk videoPlayerStart: %s", LSMessageGetPayload(msg));
	return TRUE;
}

static bool
clonk_open_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx)
{
	const char *p = LSMessageGetPayload(msg);
	gchar *uri;
	(void) sh; (void) ctx;
	uri = get_field(p, "location");
	if (uri && *uri) {
		g_free(g_clonkUri);
		g_clonkUri = uri;
		teams_call_log("clonk session open: %s", g_clonkUri);
		/* Re-push immediately so subscribers (the Phone app's ActiveCall.js) get the real
		 * videoURI without waiting for the next unrelated call-state change - mirrors
		 * WhatsApp's glue/call.c clonk_open_reply(). */
		if (g_pub || g_prv) {
			gchar *payload = build_payload();
			push_to(g_pub, payload);
			push_to(g_prv, payload);
			g_free(payload);
		}
		/* videoCaptureStart args are (w,h,fps,bitrate) on the wire, but ClonkPipeline::
		 * setCamCapsFilter() reads the wrong VideoSettings offsets (+4/+8 instead of +0/+4) - a
		 * real firmware bug (WHATSAPP_VIDEO_STATUS.md Part 16). Shifting width into the h slot
		 * and height into the fps slot lands the correct values once that bug reads them one
		 * field over. */
		clonk_uri_call("videoCaptureStart", "{\"args\":[320,320,240,400000]}",
		               clonk_capture_start_reply_cb, NULL);
	} else {
		g_free(uri);
		teams_call_log("clonk session open failed: %s", p ? p : "(no payload)");
	}
	return TRUE;
}

/* Opens a clonk session and drives it through videoCaptureStart -> skypekit_video_start() ->
 * videoPlayerStart. Call once per video call, from on_video_active_changed below. */
static void
teams_call_luna_open_clonk(void)
{
	LSError err; LSMessageToken tok;
	if (g_clonkUri || !g_prv) return;
	g_videoActive = TRUE;
	LSErrorInit(&err);
	if (!LSCallOneReply(g_prv, "palm://com.palm.mediad/service/clonk", "{}",
	                    clonk_open_reply_cb, NULL, &tok, &err)) {
		teams_call_log("clonk open call failed: %s", err.message);
		LSErrorFree(&err);
	}
}

static bool
clonk_stop_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx)
{
	(void) sh;
	teams_call_log("clonk %s: %s", (const char *) ctx, LSMessageGetPayload(msg));
	return TRUE;
}

/* Tears down the skypekit bridge + clonk session. No confirmed explicit session-teardown method
 * (mediaserver tears a session down when its creating client's LS2 connection drops, shared with
 * the rest of this long-lived process) - a fresh session is opened next time video starts. */
static void
teams_call_luna_close_clonk(void)
{
	if (!g_clonkUri) { g_videoActive = FALSE; return; }
	teams_video_relay_disconnect(); /* stop relaying to teams_media before telling mediaserver to stop */
	skypekit_video_stop();
	clonk_uri_call("videoPlayerStop", "{\"args\":[]}", clonk_stop_reply_cb, (void *) "videoPlayerStop");
	clonk_uri_call("videoCaptureStop", "{\"args\":[]}", clonk_stop_reply_cb, (void *) "videoCaptureStop");
	g_free(g_clonkUri); g_clonkUri = NULL;
	g_videoActive = FALSE;
}

static bool
clonk_keyframe_start_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx)
{
	(void) sh; (void) ctx;
	teams_call_log("clonk keyframe-restart videoCaptureStart: %s", LSMessageGetPayload(msg));
	return TRUE;
}

static bool
clonk_keyframe_stop_reply_cb(LSHandle *sh, LSMessage *msg, void *ctx)
{
	(void) sh; (void) ctx;
	teams_call_log("clonk keyframe-restart videoCaptureStop: %s", LSMessageGetPayload(msg));
	/* Thread A/B and the clonk session itself stay up throughout - only the capture pipeline
	 * restarts, so no skypekit_video_start()/videoPlayerStart here. */
	clonk_uri_call("videoCaptureStart", "{\"args\":[320,320,240,400000]}", clonk_keyframe_start_reply_cb, NULL);
	return TRUE;
}

/* No LS2-exposed keyframe trigger exists on the clonk surface, so force a fresh SPS/PPS/IDR by
 * restarting capture instead. Not currently wired to a real PLI/FIR (no RTX/NACK/PLI handling in
 * this build - see the video plan's known limitations); kept for parity with WhatsApp/Telegram
 * and as a manual diagnostic hook. */
static void
teams_call_luna_request_keyframe(void)
{
	if (!g_clonkUri) return;
	teams_call_log("keyframe requested, restarting capture");
	clonk_uri_call("videoCaptureStop", "{\"args\":[]}", clonk_keyframe_stop_reply_cb, NULL);
}

/* teams_calling_set_video_cb() handler: open/close the clonk bridge as call->video_active flips,
 * in either direction (inbound renegotiation, video already active in the initial offer/answer,
 * or the callee's confirmation of an outgoing dial-with-video request). */
static void
on_video_active_changed(TeamsAccount *sa, gboolean active)
{
	(void) sa;
	teams_call_log("video_active changed -> %d", (int) active);
	if (active) teams_call_luna_open_clonk();
	else        teams_call_luna_close_clonk();
}
