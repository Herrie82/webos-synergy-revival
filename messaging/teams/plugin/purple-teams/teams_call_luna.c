/*
 * Teams NGC calling - webOS LS2 bridge (com.palm.teams.call). See teams_call_luna.h.
 * Ported from the Telegram call-luna.cpp mediator, in C, driving teams_calling.c.
 */

#include "teams_call_luna.h"
#include "teams_calling.h"

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
	GString *p = g_string_new("{\"returnValue\":true,\"allowVideoCalls\":false,\"videoURI\":\"\",\"lines\":[");
	if (g_state && *g_state) {
		gchar *addr = g_strescape(g_peerAddr ? g_peerAddr : "", "");
		gchar *name = g_strescape((g_peerName && *g_peerName) ? g_peerName : (g_peerAddr ? g_peerAddr : ""), "");
		gchar *cause = g_strescape(g_cause ? g_cause : "", "");

		g_string_append_printf(p, "{\"state\":\"%s\",", g_state);
		if (g_strcmp0(g_state, "disconnected") == 0)
			g_string_append_printf(p, "\"disconnectDetails\":{\"cause\":\"%s\"},", cause);
		g_string_append_printf(p,
			"\"calls\":[{\"id\":\"teams\",\"origin\":\"%s\",\"video\":false,"
			"\"transport\":\"com.palm.teams\",\"address\":\"%s\",\"displayName\":\"%s\"}]}",
			g_outgoing ? "outgoing" : "incoming", addr, name);
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
	LSError err; gchar *addr; gboolean ok;
	(void) ctx;
	LSErrorInit(&err);
	addr = get_field(LSMessageGetPayload(msg), "address");
	ok = g_sa && addr && *addr && teams_calling_dial(g_sa, addr);
	teams_call_log("cbDial addr=%s ok=%d", addr ? addr : "(null)", (int) ok);
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

gboolean
teams_call_luna_init(TeamsAccount *sa)
{
	LSError err;
	g_sa = sa;
	teams_calling_set_state_cb(on_call_state);
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
	if (active) {
		/* id MUST be a string (PmBtEngine reads the call id as a string), transport stays
		 * com.palm.teams (the 1-byte PmBtEngine patch accepts non-skype transports). */
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate",
		            "{\"lines\":[{\"state\":\"active\",\"calls\":[{\"id\":\"1\",\"address\":\"teams\",\"origin\":\"outgoing\",\"video\":false,\"transport\":\"com.palm.teams\"}]}]}");
		audiod_send("palm://com.palm.audio/phone/setCurrentScenario", "{\"scenario\":\"phone_back_speaker\"}");
	} else {
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate", "{\"lines\":[]}");
	}
}
