#!/bin/sh
# chatthreader-person-link-fix: make outgoing-only IM chatthreads resolve their contact name.
#
# Root cause (confirmed on-device): the chatthreader resolves a message's sender/recipient to a
# com.palm.person via ContactsLib Person.findByIM. For type_whatsapp, Messaging.Utils.normalizeAddress
# STRIPS the leading "+" ("+31612345678" -> "31612345678"), but a contact's WhatsApp im can be stored
# with the "+" KEPT in its person-record normalizedValue (seen on an aggregate person merged with a
# CardDAV/Google contact). findByIM then MISSES, so `person` is undefined and the chatthread is created
# with no personId and displayName == the bare number. Incoming threads hide this because they inherit
# displayName from the message's from.name; an OUTGOING-only thread (you composed to the number, never
# received) has no such fallback -> the conversation shows "+31612345678" instead of the contact name.
#
# The buddy record (com.palm.imbuddystatus, TempDB) is keyed on the EXACT raw username ("+31612345678")
# and already carries the right personId + displayName (set by personChanged.addPersonIdToBuddy, an
# exact-match path that does NOT depend on the flaky normalized im index). So the fix: when
# Person.findByIM returns nothing, fall back to imbuddystatus -> personId -> person. Zero cost for
# already-resolved contacts (only fires on a findByIM miss), indexed lookup, no new index.
#
# Patched file: assistants/newmessageassistant.js (contactReverseLookup + new findPersonViaBuddy).
# The chatthreader is forked per-activity, so the new JS loads on the next message; no restart needed.
# To also fix threads that are ALREADY broken (showing a bare number), run repair-existing-threads.sh.
#
# Reversible: backs up to newmessageassistant.js.b4personlink on-device (before overwrite).
set -e
DEV="${DEV:-topaz-linux}"
CT=/usr/palm/services/com.palm.messaging.chatthreader/assistants
HERE=$(dirname "$0")

echo "=== 1) back up the stock file on-device (before overwrite) ==="
printf '%s\n' '
CT=/usr/palm/services/com.palm.messaging.chatthreader/assistants
mount -o remount,rw / 2>/dev/null || true
if [ -f "$CT/newmessageassistant.js.b4personlink" ]; then
  echo "backup already exists: $CT/newmessageassistant.js.b4personlink"
else
  cp "$CT/newmessageassistant.js" "$CT/newmessageassistant.js.b4personlink"
  echo "backed up -> $CT/newmessageassistant.js.b4personlink"
fi
' | novacom -d "$DEV" run file://bin/sh

echo "=== 2) deploy patched newmessageassistant.js ==="
novacom -d "$DEV" put file://$CT/newmessageassistant.js < "$HERE/newmessageassistant.js"

echo "=== 3) verify ==="
printf '%s\n' '
CT=/usr/palm/services/com.palm.messaging.chatthreader/assistants
n=$(grep -c findPersonViaBuddy "$CT/newmessageassistant.js")
echo "findPersonViaBuddy hooks in deployed file: $n (expect 2)"
[ "$n" -ge 2 ] && echo "OK" || echo "WARNING: patch not present - check the put"
echo "chatthreader is forked per-activity -> new JS loads on the next message; no restart needed."
' | novacom -d "$DEV" run file://bin/sh

echo "=== 4) deploy contacts linker plugin fix (contacts.plugin.messaging/utils.js) ==="
# Canonical association layer: getUnassociatedChatThreads links pre-existing unassociated threads to a
# person when it gains an im/phone (on contact sync / re-link / merge). Its IM branch matched the
# chatthread by the im's normalizedValue verbatim ("+31612345678"), but WhatsApp chatthreads are keyed
# without the "+" ("31612345678") -> miss -> never linked. Fix strips the "+" for type_whatsapp.
PLG=/usr/palm/frameworks/contacts.plugin.messaging/submission/12.1/javascript
printf '%s\n' '
PLG=/usr/palm/frameworks/contacts.plugin.messaging/submission/12.1/javascript
mount -o remount,rw / 2>/dev/null || true
[ -f "$PLG/utils.js.b4whatsappnorm" ] || cp "$PLG/utils.js" "$PLG/utils.js.b4whatsappnorm"
echo "backed up -> $PLG/utils.js.b4whatsappnorm"
' | novacom -d "$DEV" run file://bin/sh
novacom -d "$DEV" put file://$PLG/utils.js < "$HERE/contacts-plugin-messaging-utils.js"
printf '%s\n' '
PLG=/usr/palm/frameworks/contacts.plugin.messaging/submission/12.1/javascript
n=$(grep -c type_whatsapp "$PLG/utils.js")
echo "type_whatsapp guard in deployed utils.js: $n (expect 2)"
kill $(pidof com.palm.service.contacts.linker) 2>/dev/null
echo "contacts linker killed -> reloads the plugin on the next autolink."
' | novacom -d "$DEV" run file://bin/sh

echo "=== done. Source of truth is git ($HERE/). ==="
echo "Undo: restore newmessageassistant.js.b4personlink and utils.js.b4whatsappnorm; they reload on next message / autolink."
echo "NOTE: run repair-existing-threads.sh once to fix threads that are ALREADY broken (show a bare number)."
