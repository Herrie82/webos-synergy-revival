#!/bin/sh
# Deploy the WhatsApp group-name JID guard to the on-device chatthreader (stock Palm service, not
# vendored). Pairs with the imtransport fix (LibpurpleAdapter: don't stamp a raw group JID as
# channelDisplayName). Idempotent; backs up originals to *.b4jidguard. Run over novacom.
set -e
CT=/usr/palm/services/com.palm.messaging.chatthreader/models
HERE=$(dirname "$0")
mount -o remount,rw / 2>/dev/null || true

# 1) imchannel.js: adds DBModels.ImChannel._isRawId + rejects a raw JID as the channel displayName
#    (update branch) and never stores the JID as displayName on create.
[ -f "$CT/imchannel.js.b4jidguard" ] || cp "$CT/imchannel.js" "$CT/imchannel.js.b4jidguard"
cp "$HERE/imchannel.js" "$CT/imchannel.js"

# 2) dbmodels.js: guard the channel-thread self-heal so it never copies a raw-JID channel name onto
#    the thread. One-line, applied in place (the file is large + stock, so we sed rather than ship it).
[ -f "$CT/dbmodels.js.b4jidguard" ] || cp "$CT/dbmodels.js" "$CT/dbmodels.js.b4jidguard"
sed -i 's/if (channelRec \&\& channelRec.displayName \&\& results\[0\].displayName !== channelRec.displayName) {/if (channelRec \&\& channelRec.displayName \&\& !DBModels.ImChannel._isRawId(channelRec.displayName, channelAddr) \&\& results[0].displayName !== channelRec.displayName) {/' "$CT/dbmodels.js"

echo "installed. _isRawId in imchannel.js: $(grep -c _isRawId "$CT/imchannel.js"); in dbmodels.js: $(grep -c _isRawId "$CT/dbmodels.js")"
echo "chatthreader is forked per-activity (node_fork_server) -> new JS loads on the next message; no restart needed."
