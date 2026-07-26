#!/bin/bash
# backfill-chatthread-persons.sh — re-link stale 1:1 chat threads to their unified Contacts person.
#
# Runs from the HOST over novacom (like db8-health-audit.sh). READ-ONLY unless --apply is given.
#
# Why: a 1:1 chatthread caches its displayName + personId at the moment the FIRST message arrives.
# If the contacts linker hadn't yet produced the com.palm.person for that IM buddy (a race on first
# contact), the chatthreader falls back to the raw address — so the thread shows "+31687006611" with
# no personId, and never re-resolves. The person IS findable now (Person.findByIM matches the buddy's
# ims.value/ims.normalizedValue), it just was too late for that thread.
#
# This backfill finds every thread whose displayName is still the raw reply address AND has no
# personId, looks up the unified person by that IM address, and (with --apply) writes personId + the
# person's real name onto the thread. Conservative: it only touches threads that still look unresolved
# and that map to exactly ONE named person; anything ambiguous is reported and skipped.
#
# Usage:  ./backfill-chatthread-persons.sh                 # DRY RUN (auto-detect device)
#         ./backfill-chatthread-persons.sh --apply         # write the fixes
#         ./backfill-chatthread-persons.sh <deviceid> --apply
set -u

DEVICE=""; APPLY=0
for a in "$@"; do case "$a" in --apply) APPLY=1 ;; *) DEVICE="$a" ;; esac; done
NOVA=(novacom); [ -n "$DEVICE" ] && NOVA=(novacom -d "$DEVICE")
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
READER="com.palm.app.messaging"              # kind perms grant it read on chatthread + person
WRITER="com.palm.messaging.chatthreader"     # owner of com.palm.chatthread:1 (write)

dev() { printf '%s\n' "$1" | "${NOVA[@]}" run file://bin/sh 2>/dev/null; }
dbfind() { dev "luna-send -i -n 1 -a $READER luna://com.palm.db/find '$1' </dev/null 2>&1"; }
dbmerge() { dev "luna-send -i -n 1 -a $WRITER luna://com.palm.db/merge '$1' </dev/null 2>&1"; }

# fetch_all KIND SELECT_JSON OUTFILE — paginate (db8 caps limit at 500), merge pages host-side.
fetch_all() {
	local kind="$1" sel="$2" out="$3" page="" all="$WORK/.pages" n=0
	: > "$all"
	while :; do
		local q="{\"query\":{\"from\":\"$kind\",\"select\":$sel,\"limit\":500"
		[ -n "$page" ] && q="$q,\"page\":\"$page\""
		q="$q}}"
		local resp; resp="$(dbfind "$q")"
		printf '%s\n' "$resp" >> "$all"
		page="$(printf '%s' "$resp" | grep -oE '"next":"[^"]+"' | head -1 | sed 's/"next":"//;s/"$//')"
		n=$((n+1)); [ -z "$page" ] && break; [ "$n" -gt 200 ] && break
	done
	python3 - "$all" "$out" <<'PY'
import sys,json,re
res=[]
for m in re.finditer(r'\{.*\}', open(sys.argv[1]).read()):
    try: d=json.loads(m.group(0))
    except Exception: continue
    if isinstance(d,dict) and d.get('returnValue') and 'results' in d: res.extend(d['results'])
json.dump({'results':res}, open(sys.argv[2],'w'))
PY
}

if ! dev "echo ok" | grep -q ok; then echo "!! cannot reach device over novacom"; exit 2; fi
echo "== fetching chatthreads + persons =="
fetch_all "com.palm.chatthread:1" '["_id","displayName","replyAddress","normalizedAddress","replyService","personId"]' "$WORK/threads.json"
fetch_all "com.palm.person:1"     '["_id","ims","name","names","nickname"]'                                             "$WORK/persons.json"

# Match + build the update plan (host-side python). Emits a JSON array of {_id,personId,displayName}
# to $WORK/plan.json and prints a human report. Never writes to the device here.
python3 - "$WORK/threads.json" "$WORK/persons.json" "$WORK/plan.json" <<'PY'
import sys,json,re
threads=json.load(open(sys.argv[1]))["results"]
persons=json.load(open(sys.argv[2]))["results"]

# index IM address -> set of persons (both raw value and normalizedValue)
idx={}
def add(k,p):
    if not k: return
    idx.setdefault(k,set()).add(p["_id"])
pby={p["_id"]:p for p in persons}
for p in persons:
    for im in (p.get("ims") or []):
        add(im.get("value"),p); add(im.get("normalizedValue"),p)

def person_name(p):
    # A person can carry several names (its `names[]` + primary `name`): the user's real contact name
    # AND an IM network push-name ("Vladushka") that a re-sync may have promoted to primary. Prefer a
    # name that has BOTH givenName and familyName (a real contact name) over a single-word push-name,
    # then any structured name, then the nickname (for handle-only contacts like Telegram usernames).
    cands=list(p.get("names") or [])
    if p.get("name"): cands.append(p["name"])
    def full(n): return " ".join(x for x in [(n.get("givenName") or "").strip(), (n.get("familyName") or "").strip()] if x).strip()
    both=[full(n) for n in cands if (n.get("givenName","").strip() and n.get("familyName","").strip())]
    if both: return both[0]
    any_=[full(n) for n in cands if full(n)]
    if any_: return any_[0]
    return (p.get("nickname") or "").strip()

def looks_raw(t):
    dn=str(t.get("displayName") or "")
    if not dn: return True
    for a in (t.get("replyAddress"), t.get("normalizedAddress")):
        if a and dn==str(a): return True
    if dn and (dn.replace("+","").isdigit() or "@" in dn):  # bare phone or JID
        return True
    return False

plan=[]; skipped=[]; ok=[]
for t in threads:
    if t.get("personId"):            # already linked
        ok.append(t); continue
    if not looks_raw(t):             # has a real name already, don't touch
        ok.append(t); continue
    keys=[t.get("replyAddress"), t.get("normalizedAddress")]
    cands=set()
    for k in keys:
        cands |= idx.get(k,set())
    named=[pid for pid in cands if person_name(pby[pid])]
    if len(named)==1:
        p=pby[named[0]]
        plan.append({"_id":t["_id"], "personId":p["_id"], "displayName":person_name(p)})
    else:
        skipped.append((t.get("displayName"), t.get("replyService"), len(cands), len(named)))

json.dump(plan, open(sys.argv[3],"w"))
print(f"threads total={len(threads)}  already-linked/named={len(ok)}  TO FIX={len(plan)}  ambiguous/no-person={len(skipped)}")
print("\n-- will re-link --")
for u in plan: print(f"  thread {u['_id']}  ->  personId {u['personId']}  displayName {u['displayName']!r}")
if skipped:
    print("\n-- skipped (0 or >1 matching named person) --")
    for dn,svc,nc,nn in skipped: print(f"  displayName={dn!r} service={svc} candidates={nc} named={nn}")
PY

COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/plan.json")"
if [ "$APPLY" != "1" ]; then
	echo ""; echo "DRY RUN — nothing written. Re-run with --apply to write the $COUNT fix(es) above."
	exit 0
fi
[ "$COUNT" = "0" ] && { echo "nothing to apply."; exit 0; }

echo ""; echo "== applying $COUNT merge(s) as $WRITER =="
# merge one object at a time so a single permission/validation error is obvious
python3 -c 'import json,sys
for u in json.load(open(sys.argv[1])): print(json.dumps({"objects":[u]}))' "$WORK/plan.json" | \
while IFS= read -r obj; do
	resp="$(dbmerge "$obj")"
	if printf '%s' "$resp" | grep -q '"returnValue":true'; then
		echo "  ok: $(printf '%s' "$obj" | python3 -c 'import json,sys;o=json.load(sys.stdin)["objects"][0];print(o["_id"],"->",o["displayName"])')"
	else
		echo "  FAIL: $resp"
		echo "    (if permission-denied: com.palm.chatthread:1 write may need a different owner than $WRITER)"
	fi
done
echo "done. Reopen Messaging (or restart LunaSysMgr) to see the re-linked thread names."
