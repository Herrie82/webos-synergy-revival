#ifndef _CALL_LUNA_H
#define _CALL_LUNA_H

/* webOS Synergy Revival - Telegram calling M2 (Path C).
 *
 * The prpl already does the whole call: TDLib signaling + libtgvoip media (see call.cpp). Its only
 * webOS problem is the *UI* - the pidgin-style purple_request_action dialog + the media-caps gate.
 * This module replaces that UI with the webOS call contract: it registers an LS2 service
 * (com.palm.telegram.call) that the stock Phone app's CallSynergizer drives, exactly like the
 * WhatsApp mediator (com.palm.whatsapp) - so the stock dialer / in-call screen / call log handle
 * Telegram calls with no new UI, reusing this plugin's single logged-in TDLib session.
 *
 * Registered from inside imlibpurpletransport (the plugin's host) on libpurple's glib mainloop;
 * the transport's LS2 role must allow the name com.palm.telegram.call.
 */

#include <purple.h>

/* Register the com.palm.telegram.call service (idempotent) and bind it to this Telegram account.
 * Call when the account connects. Returns false (and logs) if LS2 registration fails. */
bool callLunaInit(PurpleAccount *account);

/* Tear down the service (account disconnect / plugin unload). */
void callLunaShutdown(PurpleAccount *account);

/* On-device trace to /media/internal/tgcall.log (purple_debug doesn't reach the system log on webOS).
 * printf-style; usable from call.cpp too (e.g. to trace the libtgvoip activateCall setup). */
void tgcLog(const char *fmt, ...);

/* Drive audiod's phone scenario so the libtgvoip "voip"/"voipsource" PCMs carry real loudspeaker/mic
 * audio. Call with true when the call becomes active, false on hangup. Mirrors wacallm. */
void callLunaSetCallAudio(bool active);

/* Push the current call state to Phone-app callStateQuery subscribers. Called from call.cpp's
 * updateCall(). state is one of: "incoming", "dialing", "active", "disconnected", "" (idle).
 * NOTE: these strings must match the stock Phone app CallSynergizer STATES enum exactly
 * (incoming/dialing/active/disconnected) or the call card won't render the state.
 * peerAddress = the Telegram user's +E.164 / id; peerName = resolved display name (may be NULL).
 * cause is only meaningful for "disconnected" (e.g. "rejected", "normal", "missed"). */
void callLunaPushState(const char *state, const char *peerAddress, const char *peerName,
                       bool isOutgoing, const char *cause);

#endif
