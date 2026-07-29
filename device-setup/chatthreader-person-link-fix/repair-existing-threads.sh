#!/bin/sh
# repair-existing-threads.sh — one-shot repair of 1:1 IM chatthreads created BEFORE their contact
# resolved (see install.sh for the root cause). Such threads have no personId and a bare address as their
# displayName. Joins them to the authoritative buddy link (com.palm.imbuddystatus, which carries
# personId + displayName) by exact replyAddress==username and stamps personId + displayName.
#
# Idempotent: threads that already have a personId are skipped. Safe to re-run. Pairs with the
# newmessageassistant.js fix (install.sh), which stops NEW threads landing unassociated — so this only
# needs running once, after install. Pushes repair-ondevice.sh and runs it (db8 paging + a node join).
set -e
DEV="${DEV:-topaz-linux}"
HERE=$(dirname "$0")
novacom -d "$DEV" put file:///media/internal/repair-ondevice.sh < "$HERE/repair-ondevice.sh"
printf 'sh /media/internal/repair-ondevice.sh 2>&1; rm -f /media/internal/repair-ondevice.sh\n' | novacom -d "$DEV" run file://bin/sh
echo "=== repair done ==="
