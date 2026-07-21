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
#include <cstdio>
#include <ctime>
#include <cstdarg>

/* Implemented in call.cpp - drive the active account's TDLib call via the existing prpl logic. */
extern bool callBridgeDial(PurpleAccount *account, const char *who);
extern void callBridgeAnswer(PurpleAccount *account);
extern void callBridgeHangup(PurpleAccount *account);

/* On-device lifecycle trace (purple_debug never reaches /var/log/messages on webOS). Tail
 * /media/internal/tgcall.log to see exactly when/if the call service registers + dials. */
void tgcLog(const char *fmt, ...)
{
    FILE *f = fopen("/media/internal/tgcall.log", "a");
    if (!f) return;
    time_t t = time(NULL);
    char ts[32]; struct tm tmv; localtime_r(&t, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    fprintf(f, "%s ", ts);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

namespace {

LSPalmService *g_service  = NULL;   // pub+priv registration
LSHandle      *g_pub      = NULL;   // public connection (untrusted apps talk here)
LSHandle      *g_prv      = NULL;   // private connection (trusted Palm apps, incl. com.palm.app.phone, talk here)
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
        // CallSynergizer reads call.address / call.displayName DIRECTLY off each call
        // (new CallSynergyContact({address: call.address, displayName: call.displayName})), and
        // CallSynergyContact.create() does enyo.require(address != undefined) which THROWS if
        // address is missing - aborting the whole callStateQuery handler before the call card is
        // shown. So the fields MUST be flat (like wacallm/TIL), not nested under "contact".
        p += "\"calls\":[{\"id\":\"tg\",\"origin\":\"" + std::string(g_outgoing ? "outgoing" : "incoming") + "\","
             "\"video\":false,"
             "\"address\":\"" + jsonEscape(g_peerAddr.c_str()) + "\","
             "\"displayName\":\"" + jsonEscape(g_peerName.empty() ? g_peerAddr.c_str() : g_peerName.c_str()) + "\"}]}";
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
    tgcLog("cbDial addr=%s g_account=%p ok=%d", addr.c_str(), (void*)g_account, ok);
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
    tgcLog("callLunaInit ENTER account=%s g_service=%p",
           account ? purple_account_get_username(account) : "(null)", (void*)g_service);
    g_account = account;
    if (g_service) return true;   // already registered (one service, whichever account connects first)

    LSError err; LSErrorInit(&err);
    if (!LSRegisterPalmService("com.palm.telegram.call", &g_service, &err)) {
        purple_debug_error(config::pluginId, "LSRegisterPalmService: %s\n", err.message);
        tgcLog("callLunaInit FAIL LSRegisterPalmService: %s", err.message);
        LSErrorFree(&err); return false;
    }
    if (!LSPalmServiceRegisterCategory(g_service, "/", g_methods, g_methods, NULL, NULL, &err)) {
        purple_debug_error(config::pluginId, "RegisterCategory: %s\n", err.message);
        tgcLog("callLunaInit FAIL RegisterCategory: %s", err.message);
        LSErrorFree(&err); return false;
    }
    // Attach to the context libpurple already services (its glib eventloop runs the default context).
    g_loopRef = g_main_loop_new(g_main_context_default(), FALSE);
    if (!LSGmainAttachPalmService(g_service, g_loopRef, &err)) {
        purple_debug_error(config::pluginId, "GmainAttach: %s\n", err.message);
        tgcLog("callLunaInit FAIL GmainAttach: %s", err.message);
        LSErrorFree(&err); return false;
    }
    g_pub = LSPalmServiceGetPublicConnection(g_service);
    g_prv = LSPalmServiceGetPrivateConnection(g_service);
    purple_debug_info(config::pluginId, "com.palm.telegram.call registered\n");
    tgcLog("callLunaInit OK - com.palm.telegram.call REGISTERED, g_pub=%p", (void*)g_pub);
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
    tgcLog("pushState state=%s addr=%s g_pub=%p g_prv=%p", g_state.c_str(), g_peerAddr.c_str(), (void*)g_pub, (void*)g_prv);
    if (!g_pub && !g_prv) return;
    std::string payload = buildPayload();
    // A subscriber's subscription lives on whichever connection it arrived on: untrusted apps come
    // in on the public connection, trusted Palm apps (the stock Phone app / CallSynergizer) on the
    // private one. LSSubscriptionReply only walks the list of the handle it's given, so push on BOTH
    // - otherwise the Phone app gets only the initial reply and never the live dialing/active pushes.
    if (g_pub) {
        LSError err; LSErrorInit(&err);
        LSSubscriptionReply(g_pub, SUBKEY, payload.c_str(), &err);
        if (LSErrorIsSet(&err)) { purple_debug_warning(config::pluginId, "pushState pub: %s\n", err.message); LSErrorFree(&err); }
    }
    if (g_prv) {
        LSError err; LSErrorInit(&err);
        LSSubscriptionReply(g_prv, SUBKEY, payload.c_str(), &err);
        if (LSErrorIsSet(&err)) { purple_debug_warning(config::pluginId, "pushState prv: %s\n", err.message); LSErrorFree(&err); }
    }
}

// --- webOS call-audio routing (mirrors the working wacallm path) --------------------------------
// libtgvoip captures/plays via the PulseAudio "voipsource"/"voip" PCMs, but those only carry the
// real mic/loudspeaker when audiod has the PHONE scenario active. Tell audiod a voip call is up on
// connect (route to loudspeaker; it auto-switches to headset/BT), and clear it on hangup.
static bool audiodReply(LSHandle *sh, LSMessage *m, void *ctx) { (void)sh; (void)m; (void)ctx; return true; }
static void audiodSend(const char *uri, const char *payload)
{
    if (!g_prv) return;
    LSError err; LSErrorInit(&err);
    LSMessageToken tok;
    if (!LSCallOneReply(g_prv, uri, payload, audiodReply, NULL, &tok, &err)) {
        purple_debug_warning(config::pluginId, "audiod %s: %s\n", uri, err.message);
        LSErrorFree(&err);
    }
}
void callLunaSetCallAudio(bool active)
{
    tgcLog("callLunaSetCallAudio active=%d g_prv=%p", (int)active, (void*)g_prv);
    if (active) {
        audiodSend("palm://com.palm.audio/phone/CallStatusUpdate",
                   "{\"lines\":[{\"state\":\"active\",\"calls\":[{\"id\":1,\"address\":\"telegram\",\"origin\":\"outgoing\",\"video\":false,\"transport\":\"com.palm.telegram\"}]}]}");
        audiodSend("palm://com.palm.audio/phone/setCurrentScenario", "{\"scenario\":\"phone_back_speaker\"}");
    } else {
        audiodSend("palm://com.palm.audio/phone/CallStatusUpdate", "{\"lines\":[]}");
    }
}
