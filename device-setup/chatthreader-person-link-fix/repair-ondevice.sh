#!/bin/sh
# Runs ON THE DEVICE (pushed + executed by repair-existing-threads.sh). Dumps chatthreads + imbuddystatus
# (paged, db8 limit is 500), joins them in node by exact replyAddress==username, and merges personId +
# displayName onto any 1:1 thread that has no personId. Idempotent. See install.sh for the root cause.
A="-a com.palm.configurator"
WORK=/media/internal/.threadrepair
rm -rf "$WORK"; mkdir -p "$WORK"

# page through a kind into $WORK/<tag>.<i>.json ; stops on empty cursor, short page, or 40-page cap
dump_kind() {
	svc="$1"; kind="$2"; tag="$3"; page=""; i=0
	while : ; do
		if [ -z "$page" ]; then
			q="{\"query\":{\"from\":\"$kind\",\"limit\":500}}"
		else
			q="{\"query\":{\"from\":\"$kind\",\"limit\":500,\"page\":\"$page\"}}"
		fi
		(sleep 2) | luna-send -i $A palm://$svc/find "$q" > "$WORK/$tag.$i.json" 2>/dev/null
		page=$(node -e 'var fs=require("fs");try{var r=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(r.next||"");}catch(e){}' "$WORK/$tag.$i.json" 2>/dev/null)
		n=$(node -e 'var fs=require("fs");try{var r=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(String((r.results||[]).length));}catch(e){process.stdout.write("0");}' "$WORK/$tag.$i.json" 2>/dev/null)
		i=$((i+1))
		[ -z "$page" ] && break
		case "$n" in ''|*[!0-9]*) n=0 ;; esac
		[ "$n" -lt 500 ] && break
		[ "$i" -ge 40 ] && { echo "WARN: $tag hit 40-page cap"; break; }
	done
}

echo "paging chatthreads..."
dump_kind com.palm.db      com.palm.chatthread:1     threads
echo "paging imbuddystatus..."
dump_kind com.palm.tempdb  com.palm.imbuddystatus:1  buddies

node -e '
var fs=require("fs"), dir="/media/internal/.threadrepair";
function loadAll(tag){
  var out=[], i=0;
  while(i<200){
    var data;
    try{ data=fs.readFileSync(dir+"/"+tag+"."+i+".json","utf8"); }catch(e){ break; }
    try{ var r=JSON.parse(data); (r.results||[]).forEach(function(x){out.push(x);}); }catch(e){}
    i++;
  }
  return out;
}
var threads=loadAll("threads"), buddies=loadAll("buddies");
var byUser={};
buddies.forEach(function(b){
  if(b.personId && b.username){
    if(!byUser[b.username] || (!byUser[b.username].displayName && b.displayName)) byUser[b.username]=b;
  }
});
var objs=[];
threads.forEach(function(t){
  if(t.personId) return;      // already linked
  if(t.groupChatId) return;   // group/channel thread, not a 1:1
  if(!t.replyAddress) return;
  var b=byUser[t.replyAddress];
  if(!b) return;
  var o={_id:t._id, personId:b.personId};
  if(b.displayName) o.displayName=b.displayName;
  objs.push(o);
});
fs.writeFileSync(dir+"/merges.json", JSON.stringify({objects:objs}));
fs.writeFileSync(dir+"/count.txt", String(objs.length));
console.log("threads="+threads.length+" linked-buddies="+Object.keys(byUser).length+" threads-to-repair="+objs.length);
'

CNT=$(cat "$WORK/count.txt" 2>/dev/null)
case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
if [ "$CNT" -gt 0 ]; then
	echo "merging $CNT repaired thread(s)..."
	(sleep 3) | luna-send -i $A palm://com.palm.db/merge "$(cat /media/internal/.threadrepair/merges.json)" | cut -c1-400
	echo ""
else
	echo "nothing to repair (all 1:1 threads already linked)."
fi
rm -rf "$WORK"
echo "repair complete."
