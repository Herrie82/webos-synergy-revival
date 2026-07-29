#!/bin/sh
# whatsapp-e164-normalization — make WhatsApp conversations resolve their contact name, PROPERLY, by
# unifying the address representation across the two frameworks that were disagreeing.
#
# Root cause: the contacts framework's IMAddress.normalizeIm only lowercases+trims, so a contact's
# WhatsApp im normalizedValue KEEPS the "+" ("+31612345678"). The messaging library's normalizeAddress
# used to strip the "+" to key chatthreads on the bare number ("31612345678"). The two never matched, so
# a thread could not link to its contact/person -> the conversation showed the bare number.
#
# Proper fix = pick ONE canonical form (E.164, "+phone") everywhere:
#   1. messaging.library normalizeAddress canonicalizes WhatsApp to "+phone" (committed in core-apps;
#      shipped here as messaging.library-utils.js + messaging.library-concatenated.js).
#   2. one-time migration of existing bare-keyed WhatsApp chatthreads -> "+phone" (migrate-ondevice.sh),
#      so they don't fork when the new normalize starts producing "+phone".
#   3. the earlier contacts.plugin.messaging/utils.js "+"-strip band-aid is REVERTED to stock — under
#      E.164 the stock getUnassociatedChatThreads matches verbatim (person im "+phone" == thread key).
#
# Order matters (see below). There is a tiny window between migrating the keys and the new lib loading
# where an in-flight WhatsApp message could fork a thread; migrate-ondevice.sh reports any such dup for a
# manual merge. Ideally run while not actively WhatsApp-chatting.
#
# NOTE: the running Messaging app caches the framework JS; relaunch it (close the card + reopen) so it
# picks up the new normalizeAddress. The chatthreader forks per-activity, so it loads the new lib on the
# next message automatically.
set -e
DEV="${DEV:-topaz-linux}"
HERE=$(dirname "$0")
M=/usr/palm/frameworks/messaging.library/submission/1.3
PLG=/usr/palm/frameworks/contacts.plugin.messaging/submission/12.1/javascript

echo "=== 1) migrate existing WhatsApp thread keys bare -> +phone (BEFORE swapping the lib) ==="
novacom -d "$DEV" put file:///media/internal/migrate-ondevice.sh < "$HERE/migrate-ondevice.sh"
printf 'sh /media/internal/migrate-ondevice.sh 2>&1 | grep -v "^undefined"; rm -f /media/internal/migrate-ondevice.sh\n' | novacom -d "$DEV" run file://bin/sh

echo "=== 2) back up + deploy the E.164 messaging.library (utils.js + concatenated.js) ==="
printf 'M=%s; mount -o remount,rw / 2>/dev/null; for f in javascript/utils.js concatenated.js; do [ -f "$M/$f.b4e164" ] || cp "$M/$f" "$M/$f.b4e164"; done; echo backed-up\n' "$M" | novacom -d "$DEV" run file://bin/sh
novacom -d "$DEV" put file://$M/javascript/utils.js < "$HERE/messaging.library-utils.js"
novacom -d "$DEV" put file://$M/concatenated.js     < "$HERE/messaging.library-concatenated.js"

echo "=== 3) revert the contacts.plugin.messaging '+'-strip band-aid to stock (obsolete under E.164) ==="
printf 'PLG=%s; [ -f "$PLG/utils.js.b4whatsappnorm" ] && cp "$PLG/utils.js.b4whatsappnorm" "$PLG/utils.js" && echo "plugin reverted to stock"; kill $(pidof com.palm.service.contacts.linker) 2>/dev/null; echo "linker reload queued"\n' "$PLG" | novacom -d "$DEV" run file://bin/sh

echo "=== 4) verify ==="
printf 'M=%s; echo "E164 in lib: $(grep -c "prefix .+. for a bare" $M/javascript/utils.js $M/concatenated.js | tr "\n" " ")"\n' "$M" | novacom -d "$DEV" run file://bin/sh
echo "=== done. RELAUNCH the Messaging app so it loads the new normalizeAddress. ==="
echo "Undo: restore *.b4e164 (lib) + re-run migrate with +phone->bare; restore contacts plugin from git."
