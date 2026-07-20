/* webOS Synergy Revival - Telegram calling M2 (Path C): the LS2 call service.
 * See call-luna.h. Serves com.palm.telegram.call to the stock Phone app (CallSynergizer),
 * mirroring the com.palm.whatsapp / wacallm contract:
 *   - callStateQuery  (subscription) : streams line/call state to the dialer
 *   - dial {address}                 : place an outgoing call
 *   - answer {id}                    : accept the pending incoming call
 *   - disconnect {id} / hangupAll    : end the current call
 * The heavy lifting (TDLib signaling + libtgvoip media) already lives in call.cpp; this only
 * translates the webOS call contract to/from the small bridge functions below.
 */

#include "call-luna.h"
#include "config.h"
#include <lunaservice.h>
#include <glib.h>
#include <string>

/* Implemented in call.cpp - drive the active account's TDLib call via the existing prpl logic. */
extern bool callBridgeDial(PurpleAccount *account, const char *who);
extern void callBridgeAnswer(PurpleAccount *account);
extern void callBridgeHangup(PurpleAccount *account);

namespace {

LSPalmService *g_service  = NULL;   // pub+priv registration
LSHandle      *g_pub      = NULL;   // public connection (apps talk here)
PurpleAccount *g_account  = NULL;   // the bound Telegram account
GMainLoop     *g_loopRef  = NULL;   // wraps the default context libpurple runs

// Last state we pushed, so a late subscriber gets the current picture immediately.
std::string    g_state, g_peerAddr, g_peerName, g_cause;
bool           g_outgoing = false;

const char *SUBKEY = "callState";

std::string jsonEscape(const char *s)
{
    std::string o;
    for (const char *p = s ? s : ""; *p; ++p) {
        switch (*p) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            default:   o += *p;     break;
        }
    }
    return o;
}

// Build the CallSynergizer callStateQuery payload. Dispatch is on the LINE-level "state"
// (handleIncoming/handleActive/handleDisconnected); an empty state => idle (no lines).
std::string buildPayload()
{
    std::string p = "{\"returnValue\":true,\"allowVideoCalls\":false,\"videoURI\":\"\",\"lines\":[";
    if (!g_state.empty()) {
        p += "{\"state\":\"" + jsonEscape(g_state.c_str()) + "\",";
        if (g_state == "disconnected")
            p += "\"disconnectDetails\":{\"cause\":\"" + jsonEscape(g_cause.c_str()) + "\"},";
        p += "\"calls\":[{\"id\":\"tg\",\"isVideo\":false,\"contact\":{"
             "\"address\":\"" + jsonEscape(g_peerAddr.c_str()) + "\","
             "\"name\":\"" + jsonEscape(g_peerName.empty() ? g_peerAddr.c_str() : g_peerName.c_str()) + "\"}}]}";
    }
    p += "]}";
    return p;
}

bool cbCallStateQuery(LSHandle *sh, LSMessage *msg, void *)
{
    LSError err; LSErrorInit(&err);
    bool subscribed = false;
    LSSubscriptionProcess(sh, msg, &subscribed, &err);   // honours {"subscribe":true}
    if (subscribed)
        LSSubscriptionAdd(sh, SUBKEY, msg, &err);
    std::string payload = buildPayload();
    LSMessageReply(sh, msg, payload.c_str(), &err);
    if (LSErrorIsSet(&err)) { purple_debug_warning(config::pluginId, "callStateQuery: %s\n", err.message); LSErrorFree(&err); }
    return true;
}

// tiny extractor for a top-level string field (avoids pulling a JSON lib into the prpl)
std::string getField(const char *json, const char *key)
{
    if (!json) return "";
    std::string needle = std::string("\"") + key + "\"";
    const char *k = strstr(json, needle.c_str());
    if (!k) return "";
    const char *c = strchr(k + needle.size(), ':');
    if (!c) return "";
    while (*++c == ' ') ;
    if (*c != '"') return "";
    const char *e = strchr(++c, '"');
    return e ? std::string(c, e - c) : "";
}

bool cbDial(LSHandle *sh, LSMessage *msg, void *)
{
    LSError err; LSErrorInit(&err);
    std::string addr = getField(LSMessageGetPayload(msg), "address");
    bool ok = g_account && !addr.empty() && callBridgeDial(g_account, addr.c_str());
    LSMessageReply(sh, msg, ok ? "{\"returnValue\":true}" : "{\"returnValue\":false}", &err);
    if (LSErrorIsSet(&err)) LSErrorFree(&err);
    return true;
}

bool cbAnswer(LSHandle *sh, LSMessage *msg, void *)
{
    LSError err; LSErrorInit(&err);
    if (g_account) callBridgeAnswer(g_account);
    LSMessageReply(sh, msg, "{\"returnValue\":true}", &err);
    if (LSErrorIsSet(&err)) LSErrorFree(&err);
    return true;
}

bool cbDisconnect(LSHandle *sh, LSMessage *msg, void *)
{
    LSError err; LSErrorInit(&err);
    if (g_account) callBridgeHangup(g_account);
    LSMessageReply(sh, msg, "{\"returnValue\":true}", &err);
    if (LSErrorIsSet(&err)) LSErrorFree(&err);
    return true;
}

// The Phone app's manual-dial call contract methods (spec Part 3). We implement the ones a 1:1
// VoIP call needs; the rest ack so CallSynergizer doesn't error.
bool cbNoop(LSHandle *sh, LSMessage *msg, void *)
{
    LSError err; LSErrorInit(&err);
    LSMessageReply(sh, msg, "{\"returnValue\":true}", &err);
    if (LSErrorIsSet(&err)) LSErrorFree(&err);
    return true;
}

LSMethod g_methods[] = {
    { "callStateQuery", cbCallStateQuery },
    { "dial",           cbDial           },
    { "answer",         cbAnswer         },
    { "disconnect",     cbDisconnect     },
    { "hangupAll",      cbDisconnect     },
    { "hangupAllActive",cbDisconnect     },
    { "hold",           cbNoop           },
    { "swap",           cbNoop           },
    { "merge",          cbNoop           },
    { "extract",        cbNoop           },
    { "dtmf",           cbNoop           },
    { "dtmfEnd",        cbNoop           },
    { "changeMedia",    cbNoop           },
    { NULL, NULL }
};

} // namespace

bool callLunaInit(PurpleAccount *account)
{
    g_account = account;
    if (g_service) return true;   // already registered (one service, whichever account connects first)

    LSError err; LSErrorInit(&err);
    if (!LSRegisterPalmService("com.palm.telegram.call", &g_service, &err)) {
        purple_debug_error(config::pluginId, "LSRegisterPalmService: %s\n", err.message);
        LSErrorFree(&err); return false;
    }
    if (!LSPalmServiceRegisterCategory(g_service, "/", g_methods, g_methods, NULL, NULL, &err)) {
        purple_debug_error(config::pluginId, "RegisterCategory: %s\n", err.message);
        LSErrorFree(&err); return false;
    }
    // Attach to the context libpurple already services (its glib eventloop runs the default context).
    g_loopRef = g_main_loop_new(g_main_context_default(), FALSE);
    if (!LSGmainAttachPalmService(g_service, g_loopRef, &err)) {
        purple_debug_error(config::pluginId, "GmainAttach: %s\n", err.message);
        LSErrorFree(&err); return false;
    }
    g_pub = LSPalmServiceGetPublicConnection(g_service);
    purple_debug_info(config::pluginId, "com.palm.telegram.call registered\n");
    return true;
}

void callLunaShutdown(PurpleAccount *account)
{
    if (g_account == account) g_account = NULL;
    // Keep the service registered for the process lifetime (cheap, and other accounts may use it).
}

void callLunaPushState(const char *state, const char *peerAddress, const char *peerName,
                       bool isOutgoing, const char *cause)
{
    g_state    = state       ? state       : "";
    g_peerAddr = peerAddress  ? peerAddress : "";
    g_peerName = peerName     ? peerName    : "";
    g_cause    = cause        ? cause       : "";
    g_outgoing = isOutgoing;
    if (!g_pub) return;
    LSError err; LSErrorInit(&err);
    std::string payload = buildPayload();
    LSSubscriptionReply(g_pub, SUBKEY, payload.c_str(), &err);
    if (LSErrorIsSet(&err)) { purple_debug_warning(config::pluginId, "pushState: %s\n", err.message); LSErrorFree(&err); }
}
