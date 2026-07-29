# whatsapp-e164-normalization — WhatsApp threads link to their contact (the proper fix)

## Symptom
A WhatsApp conversation shows the raw number (`+31684449061`) instead of the contact's name, even
though the contact is fully synced (buddy + person both carry the name).

## Root cause — two frameworks disagreeing on "+"
The same WhatsApp identity is normalized **two different ways**:

| Side | Function | `+31684449061` becomes |
| --- | --- | --- |
| Contacts framework | `IMAddress.normalizeIm` (just `toLowerCase().trim()`) | `+31684449061` (keeps "+") |
| Messaging library | `Messaging.Utils.normalizeAddress` (old: strips "+") | `31684449061` (bare) |

So a chatthread was keyed on the bare number while the contact's `ims.normalizedValue` kept the "+".
Every matcher that compares the two (the linker's `getUnassociatedChatThreads`, and thread lookups)
missed, so the thread never linked to its person → it showed the bare number. Incoming threads hid
this by borrowing the sender's `from.name`; an outgoing-only thread had no fallback.

## The fix — one canonical form (E.164, `+phone`) everywhere
1. **`messaging.library` `normalizeAddress`** now canonicalizes WhatsApp to E.164: strip
   `@s.whatsapp.net`, then ensure a leading `+` for a bare phone-number id (opaque `<id>@lid` /
   `@newsletter` are left as-is). Now the chatthread key == the contacts-side `normalizedValue`.
   (core-apps commit; shipped here as `messaging.library-utils.js` + `messaging.library-concatenated.js`.)
2. **One-time migration** (`migrate-ondevice.sh`) rekeys existing bare WhatsApp chatthreads → `+phone`
   so they don't fork when the new normalize starts emitting `+phone`.
3. **Revert** the earlier `contacts.plugin.messaging/utils.js` "+"-strip band-aid to stock — under
   E.164 the stock `getUnassociatedChatThreads` matches verbatim (`+phone` == `+phone`).

With both sides on `+phone`, `Person.findByIM` (already keeps "+") and `getUnassociatedChatThreads`
(stock) both match, so threads link to their contact at message time **and** at contact sync/relink.

## Install
`sh install.sh` (over novacom). Order: migrate keys → deploy lib → revert plugin. There is a tiny
transition window where an in-flight WhatsApp message could fork a thread; `migrate-ondevice.sh`
reports any duplicate `+phone` key for a manual merge. Best run while not actively WhatsApp-chatting.

**After install: relaunch the Messaging app** (close the card + reopen) so it loads the new
`normalizeAddress`. The chatthreader forks per-activity and picks it up on the next message.

## Verify
```
luna-send -i -a com.palm.configurator palm://com.palm.db/find \
  '{"query":{"from":"com.palm.chatthread:1","limit":500}}' | ...   # every type_whatsapp 1:1 key is "+<digits>", none bare
```

## Relation to `../chatthreader-person-link-fix`
That package's `newmessageassistant.js` imbuddystatus fallback + `repair-existing-threads.sh` remain as
a defensive backstop / a one-time repair for threads already missing a `personId`. Its
`contacts-plugin-messaging-utils.js` "+"-strip is superseded and reverted by this package.

## Undo
Restore `*.b4e164` for the lib, re-migrate `+phone`→bare, and restore the contacts plugin from git.
