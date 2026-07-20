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

/* Push the current call state to Phone-app callStateQuery subscribers. Called from call.cpp's
 * updateCall(). state is one of: "incoming", "outgoing", "active", "disconnected", "" (idle).
 * peerAddress = the Telegram user's +E.164 / id; peerName = resolved display name (may be NULL).
 * cause is only meaningful for "disconnected" (e.g. "rejected", "normal", "missed"). */
void callLunaPushState(const char *state, const char *peerAddress, const char *peerName,
                       bool isOutgoing, const char *cause);

#endif
