#!/bin/sh
# Runs ON THE DEVICE. One-time migration of existing WhatsApp 1:1 chatthread keys from bare digits
# ("31612345678") to E.164 ("+31612345678"), matching the new messaging.library normalizeAddress and the
# contacts framework's im normalizedValue. Idempotent (threads already "+..." are skipped). Group/channel
# threads (@newsletter, @g.us, @lid) are left untouched. After migrating, it detects any duplicate "+phone"
# keys (a fork created if a message landed mid-flip) and reports them for a manual merge.
A="-a com.palm.configurator"
(sleep 3) | luna-send -i $A palm://com.palm.db/find '{"query":{"from":"com.palm.chatthread:1","limit":500}}' > /media/internal/ct.json 2>/dev/null

node -e '
var fs=require("fs");
var t=(JSON.parse(fs.readFileSync("/media/internal/ct.json","utf8")).results)||[];
var objs=[];
t.forEach(function(x){
  if(x.replyService!=="type_whatsapp"||x.groupChatId) return;
  var n=x.normalizedAddress||"";
  if(/^[0-9]+$/.test(n)) objs.push({_id:x._id, normalizedAddress:"+"+n});  // bare -> +phone
});
fs.writeFileSync("/media/internal/mig.json", JSON.stringify({objects:objs}));
fs.writeFileSync("/media/internal/mig_cnt.txt", String(objs.length));
' 2>/dev/null

CNT=$(cat /media/internal/mig_cnt.txt 2>/dev/null); case "$CNT" in ''|*[!0-9]*) CNT=0;; esac
echo "migrating $CNT whatsapp thread key(s) bare -> +phone"
if [ "$CNT" -gt 0 ]; then
  (sleep 3) | luna-send -i $A palm://com.palm.db/merge "$(cat /media/internal/mig.json)" | cut -c1-200
  echo ""
fi

# post-migration dup detection (fork guard)
(sleep 3) | luna-send -i $A palm://com.palm.db/find '{"query":{"from":"com.palm.chatthread:1","limit":500}}' > /media/internal/ct2.json 2>/dev/null
node -e '
var fs=require("fs");
var t=(JSON.parse(fs.readFileSync("/media/internal/ct2.json","utf8")).results)||[];
var wa=t.filter(function(x){return x.replyService==="type_whatsapp" && !x.groupChatId;});
var bare=wa.filter(function(x){return /^[0-9]+$/.test(x.normalizedAddress||"");});
var plus=wa.filter(function(x){return /^\+[0-9]+$/.test(x.normalizedAddress||"");});
var seen={}, dups=[];
plus.forEach(function(x){ if(seen[x.normalizedAddress]) dups.push(x.normalizedAddress); else seen[x.normalizedAddress]=1; });
console.log("post-migration: whatsapp 1:1="+wa.length+"  bare-remaining="+bare.length+"  +phone="+plus.length+"  duplicate-keys="+dups.length);
if(dups.length) console.log("  DUP KEYS (merge manually): "+JSON.stringify(dups));
' 2>/dev/null

rm -f /media/internal/ct.json /media/internal/ct2.json /media/internal/mig.json /media/internal/mig_cnt.txt
echo "migration complete."
