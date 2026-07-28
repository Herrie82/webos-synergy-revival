#!/bin/sh
# Deploy the opt(b) parallel-similarity autolinker to the on-device contacts linker (stock Palm
# service, not vendored). Stock Autolinker.doRankingFunctions runs the 4 similarity rankers
# (similarName / similarPhoneNumber / similarEmail / similarIM) STRICTLY SEQUENTIALLY -- 4 serial
# db8 batch round-trips per contact. Each ranker only ADDS its own (order-independent) weight to a
# shared map, and node is single-threaded, so running them concurrently via Foundations mapReduce
# gives the identical result with the 4 read round-trips overlapped (~4 serial -> ~1). CLB
# manualLinks/unlinks stay sequential AND after the similarity pass (they use MAX/MIN override
# weights). See README.md.
#
# Idempotent; backs up the original to autolinker.js.b4optb. Run over novacom:
#   novacom -d topaz-linux run file:///bin/sh -- < install.sh
set -e
L=/usr/palm/services/com.palm.service.contacts.linker
HERE=$(dirname "$0")
mount -o remount,rw / 2>/dev/null || true

[ -f "$L/autolinker.js.b4optb" ] || cp "$L/autolinker.js" "$L/autolinker.js.b4optb"
cp "$HERE/autolinker.js" "$L/autolinker.js"

# The linker caches its JS in-process, so kill it to force a reload on the next autolink.
for p in /proc/[0-9]*; do
	grep -qa "contacts.linker" "$p/cmdline" 2>/dev/null && kill "${p##*/}" 2>/dev/null || true
done

echo "installed opt(b): parallel mapReduce blocks in autolinker.js = $(grep -c 'Foundations.Control.mapReduce' "$L/autolinker.js")"
echo "backup at $L/autolinker.js.b4optb"
echo "linker killed; loads on the next autolink run."

# To revert:
#   cp $L/autolinker.js.b4optb $L/autolinker.js  (then kill the linker as above)
