#!/bin/bash
# install-account-keepdata.sh — deploy the keepData-forwarding patch to the stock
# account service (com.palm.service.accounts) over novacom.
#
# Why: deleteAccount() accepts a `keepData` arg (set by the "Keep this account's data
# on this device" checkbox in the Accounts "Remove Account" dialog), but the stock
# account service DROPS it — notify-deleted.js calls each capability's onDelete with
# only {accountId}. These two patched handlers forward keepData end-to-end:
#
#   deleteAccount(args.keepData)
#     -> delete.js: notifyAccountDeleted({accountId, keepData})
#     -> notify-deleted.js: onDelete({accountId, keepData})
#     -> imlibpurple onDelete: keep (unlink only) vs wipe on-device data
#
# keepData absent/false => wipe (historical default). The account service is stock
# (not in a repo of its own), so we keep the patched handlers here and re-apply after
# a reflash. Files are pure JS; only these two handlers change.
#
# Usage:  ./install-account-keepdata.sh [deviceid]
set -u
DEVICE="${1:-}"
NOVA=(novacom); [ -n "$DEVICE" ] && NOVA=(novacom -d "$DEVICE")
HERE="$(cd "$(dirname "$0")" && pwd)"
DST=/usr/palm/services/com.palm.service.accounts/handlers

for f in delete.js notify-deleted.js; do
	echo "-> deploying $f"
	"${NOVA[@]}" put "file://$DST/$f" < "$HERE/handlers/$f" || { echo "!! push failed for $f"; exit 1; }
done

echo "-> restarting account service so it reloads the handlers"
cat > /tmp/.acct-restart.sh <<'EOF'
for p in $(ps 2>/dev/null | grep 'com.palm.service.accounts.js' | grep -v grep | awk '{print $1}'); do
	echo "  killing pid $p"; kill $p 2>/dev/null
done
# nudge it back up + confirm it serves
luna-send -n 1 luna://com.palm.service.accounts/listAccountTemplates '{}' >/dev/null 2>&1 &
sleep 4
echo "  delete.js keepData refs:        $(grep -c keepData $0 2>/dev/null)$(grep -c keepData /usr/palm/services/com.palm.service.accounts/handlers/delete.js)"
echo "  notify-deleted.js keepData refs: $(grep -c keepData /usr/palm/services/com.palm.service.accounts/handlers/notify-deleted.js)"
EOF
"${NOVA[@]}" put file:///tmp/.acct-restart.sh < /tmp/.acct-restart.sh
"${NOVA[@]}" run file://bin/sh -- /tmp/.acct-restart.sh
echo "done. Verify a delete logs: 'Calling onDelete ... keepData=<true|false>'"
