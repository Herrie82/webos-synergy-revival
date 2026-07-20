# Messaging-app call button — WhatsApp calling entry point

A one-tap voice-call button in the stock Messaging app's conversation header, the natural
counterpart to the dialer for IM contacts (call the person you're chatting with — no handle to
type). It hands off to the stock Phone app, so it reuses the whole `../..` (com.palm.app.phone)
calling patch set: in-call UI, call log, audio routing, `callNetworkName()`.

## Files (full patched copies of com.palm.app.messaging)

| File | Change |
|------|--------|
| `app/conversations/ConversationList.js` | Adds a call `IconButton` to the conversation-header toolbar + `voipCall`/`updateCallButton`/`gotPhoneAccounts`. **Capability-driven**: it queries `listAccounts {capability:"PHONE"}` (the same signal CallSynergizer uses), builds a `serviceName → templateId` map, and shows the button only for a **1:1** conversation on a call-capable IM service — dialling via that service's own transport. Add calling to Telegram/Signal = grant their account the PHONE capability; the button lights up with zero code change here. |
| `stylesheets/conversation.css` | `.conversation-call-btn` — transparent 32px icon button, vertically centred in the header (`top` nudge). |
| `images/voip-call-icon.png` | The handset glyph — the Phone app's PHONE-tab icon, recoloured dark for the light header (blue on press), in the 32×64 two-state format. |

## Depends on

- The **phone-app calling patch set** (`../../app-patches/com.palm.app.phone`) — especially the
  generalized `index.html` dial handler that accepts any discovered PHONE transport, and
  `Utils.callNetworkName`.
- The account carrying a **PHONE capability** (see the calling `README.md` → "Account").

## Install

Copy the files over the on-device app at
`/media/cryptofs/apps/usr/palm/applications/com.palm.app.messaging/` and relaunch Messaging.
