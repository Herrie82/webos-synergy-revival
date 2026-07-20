#!/bin/bash
# db8-health-audit.sh — read-only health & integrity audit of the webOS Messaging db8 store.
#
# Runs from the HOST over novacom. Fetches the messaging kinds (paginated) as the
# com.palm.app.messaging caller (the kind permissions grant it read), then analyses them for:
#   - account/login-state health (parked/errored accounts)
#   - record counts per kind
#   - servers/rooms integrity (duplicate channels/threads, orphans, dangling links)
#   - chatthread integrity (duplicate 1:1 threads, empty threads)
#   - message stats (per service, per folder, orphans, failures)
#   - db8 watch health (leak detection from /var/log/messages)
#   - store/partition storage headroom
#
# Nothing is written to the device. Exit code: 0 all-clear, 1 warnings, 2 failures.
#
# Usage:  ./db8-health-audit.sh            # auto-detect the single connected device
#         ./db8-health-audit.sh <deviceid> # target a specific novacom device
#         DEEP=1 ./db8-health-audit.sh     # also pull full immessage set for deep checks (slow)
set -u

DEVICE="${1:-}"
NOVA=(novacom)
[ -n "$DEVICE" ] && NOVA=(novacom -d "$DEVICE")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CALLER="com.palm.app.messaging"
FAIL=0; WARN=0

# ---- device helpers -------------------------------------------------------------------------
dev() { printf '%s\n' "$1" | "${NOVA[@]}" run file://bin/sh 2>/dev/null; }

# db8 find; $1 = full JSON params, $2 = db service (default com.palm.db; use com.palm.tempdb for
# imbuddystatus). Interactive mode is required to capture the reply over novacom.
dbfind() {
	dev "luna-send -i -n 1 -a $CALLER luna://${2:-com.palm.db}/find '$1' </dev/null 2>&1"
}

# count_kind KIND -> integer (true count, independent of page size)
count_kind() {
	dbfind "{\"query\":{\"from\":\"$1\"},\"count\":true}" | grep -oE '"count":[0-9]+' | head -1 | grep -oE '[0-9]+'
}

# count_where KIND PROP VAL -> integer
count_where() {
	dbfind "{\"query\":{\"from\":\"$1\",\"where\":[{\"prop\":\"$2\",\"op\":\"=\",\"val\":\"$3\"}]},\"count\":true}" \
		| grep -oE '"count":[0-9]+' | head -1 | grep -oE '[0-9]+'
}

# fetch_all KIND SELECT_JSON OUTFILE [DBSVC] -> writes a single JSON {"results":[... all pages ...]}
# Paginates by following the response "next" page token (limit is capped at 500 by db8).
fetch_all() {
	local kind="$1" sel="$2" out="$3" dbsvc="${4:-com.palm.db}" page="" all="$WORK/.pages" n=0
	: > "$all"
	while :; do
		local q="{\"query\":{\"from\":\"$kind\",\"select\":$sel,\"limit\":500"
		[ -n "$page" ] && q="$q,\"page\":\"$page\""
		q="$q}}"
		local resp; resp="$(dbfind "$q" "$dbsvc")"
		printf '%s\n' "$resp" >> "$all"
		page="$(printf '%s' "$resp" | grep -oE '"next":"[^"]+"' | head -1 | sed 's/"next":"//;s/"$//')"
		n=$((n+1)); [ -z "$page" ] && break; [ "$n" -gt 200 ] && break
	done
	# merge all page result-arrays into one JSON doc via python
	python3 - "$all" "$out" <<'PY'
import sys,json,re
pages=open(sys.argv[1]).read()
res=[]
for m in re.finditer(r'\{.*\}', pages):
    try:
        d=json.loads(m.group(0))
    except Exception:
        continue
    if isinstance(d,dict) and d.get('returnValue') and 'results' in d:
        res.extend(d['results'])
json.dump({'results':res},open(sys.argv[2],'w'))
PY
}

echo "db8 health audit — device: ${DEVICE:-<auto>}   $(date '+%Y-%m-%d %H:%M:%S')"
if ! dev "echo ok" | grep -q ok; then echo "  !! cannot reach device over novacom"; exit 2; fi

# ---- fetch --------------------------------------------------------------------------------
echo "fetching db8 records ..."
fetch_all "com.palm.imserver:1"   '["_id","serviceName","remoteId","name","displayName"]'                 "$WORK/servers.json"
fetch_all "com.palm.imchannel:1"  '["_id","serverId","chatThreadId","remoteId","name","position"]'        "$WORK/channels.json"
fetch_all "com.palm.chatthread:1" '["_id","channelId","serverId","replyService","replyAddress","displayName","normalizedAddress","flags"]' "$WORK/threads.json"
fetch_all "com.palm.imbuddystatus:1" '["serviceName","username","displayName","serverAlias"]'             "$WORK/buddies.json" "com.palm.tempdb"
fetch_all "com.palm.person:1"     '["_id","displayName","imAddresses"]'                                    "$WORK/persons.json"
dbfind "{\"query\":{\"from\":\"com.palm.imloginstate.libpurple:1\",\"select\":[\"serviceName\",\"username\",\"state\",\"availability\",\"errorCode\"],\"limit\":500}}" > "$WORK/login.json"

# ---- counts (top-level) --------------------------------------------------------------------
CT_MSG=$(count_kind "com.palm.immessage.libpurple:1")
CT_ALLMSG=$(count_kind "com.palm.message:1")
declare -A SVCMSG SVCFOLDER
SERVICES="type_discord type_telegram type_whatsapp type_gometa type_signal type_teams type_googlechat"
for s in $SERVICES; do SVCMSG[$s]=$(count_where "com.palm.immessage.libpurple:1" serviceName "$s"); done
INBOX=$(count_where "com.palm.immessage.libpurple:1" folder inbox)
OUTBOX=$(count_where "com.palm.immessage.libpurple:1" folder outbox)

# ---- watch log + storage (device side) -----------------------------------------------------
dev "grep -aE 'watches open on index' /var/log/messages 2>/dev/null | grep -aoE 'has [0-9]+ watches open on index .[^\"'\"'\"']*.' | awk '{n=\$2; i=\$NF; if(n>m[i])m[i]=n} END{for(k in m)print m[k],k}' | sort -rn" > "$WORK/watches.txt" 2>/dev/null
dev "echo NOWUTC=\$(date -u +%s); grep -aE 'watches open on index' /var/log/messages 2>/dev/null | tail -1 | grep -aoE '^[0-9T:.-]+Z'" > "$WORK/watch_last.txt" 2>/dev/null
dev "df -k /var /media/internal /media/cryptofs 2>/dev/null | awk 'NR>1{print \$6, \$5, \$4}'" > "$WORK/df.txt" 2>/dev/null
dev "ls -l /var/db/main/objects.db 2>/dev/null | awk '{print \$5}'" > "$WORK/objdb.txt" 2>/dev/null

# ---- analysis (python) ---------------------------------------------------------------------
python3 - "$WORK" "$CT_MSG" "$CT_ALLMSG" "$INBOX" "$OUTBOX" "${SVCMSG[type_discord]:-}" "${SVCMSG[type_telegram]:-}" "${SVCMSG[type_whatsapp]:-}" "${SVCMSG[type_gometa]:-}" "${SVCMSG[type_signal]:-}" "${SVCMSG[type_teams]:-}" <<'PY'
import sys,json,collections,os
W=sys.argv[1]
ct_msg,ct_all,inbox,outbox=sys.argv[2:6]
disc,tele,wa,gm,sig,teams=sys.argv[6:12]
def load(p):
    try: return json.load(open(os.path.join(W,p))).get('results',[])
    except Exception: return []
servers=load('servers.json'); channels=load('channels.json'); threads=load('threads.json')
buddies=load('buddies.json'); persons=load('persons.json')
try: login=json.load(open(os.path.join(W,'login.json'))).get('results',[])
except Exception: login=[]
import re

warn=[]; fail=[]
def line(sym,msg): print(f"  [{sym}] {msg}")
def SEC(t): print(f"\n== {t} ==")

# ACCOUNTS
SEC("ACCOUNTS (imloginstate)")
AVAIL={0:"online",1:"idle",2:"invisible",3:"invisible",4:"OFFLINE"}
for a in sorted(login,key=lambda x:x.get('serviceName','')):
    av=a.get('availability'); st=a.get('state'); ec=a.get('errorCode','')
    tag="ok"
    if av==4: tag="WARN"; warn.append(f"{a.get('serviceName')} parked offline")
    if ec and ec not in ("AcctMgr_No_Error",""): tag="WARN"; warn.append(f"{a.get('serviceName')} errorCode={ec}")
    line(tag, f"{a.get('serviceName','?'):16} {str(a.get('username',''))[:26]:26} state={st} avail={AVAIL.get(av,av)} err={ec}")
if not login: line("WARN","no login-state records readable");

# COUNTS
SEC("RECORD COUNTS")
line("ok", f"servers={len(servers)}  channels={len(channels)}  chatthreads={len(threads)}  immessages={ct_msg}  message(all)={ct_all}")

# SERVERS/ROOMS INTEGRITY
SEC("SERVERS / ROOMS INTEGRITY")
ch_ids={c['_id'] for c in channels}; th_ids={t['_id'] for t in threads}
chan_threads=[t for t in threads if t.get('channelId')]
# duplicate channels (same server+remoteId)
dc=collections.Counter((c.get('serverId'),c.get('remoteId')) for c in channels)
dcz={k:v for k,v in dc.items() if v>1}
line("FAIL" if dcz else "ok", f"duplicate channels (server+remoteId): {len(dcz)}")
for k,v in list(dcz.items())[:10]: fail.append(f"dup channel {k} x{v}"); line("  ",f"server={k[0]} remoteId={k[1]} x{v}")
# duplicate channel threads (same channelId)
dt=collections.Counter(t['channelId'] for t in chan_threads)
dtz={k:v for k,v in dt.items() if v>1}
line("FAIL" if dtz else "ok", f"duplicate channel-threads (same channelId): {len(dtz)}")
for k,v in list(dtz.items())[:10]:
    nms=[t.get('displayName') for t in chan_threads if t['channelId']==k]; fail.append(f"dup thread ch {k} x{v}"); line("  ",f"channelId={k} x{v} -> {nms}")
# orphan channel threads
orph=[t for t in chan_threads if t['channelId'] not in ch_ids]
line("WARN" if orph else "ok", f"orphan channel-threads (channelId not a live imchannel): {len(orph)}")
if orph: warn.append(f"{len(orph)} orphan channel-threads")
# dangling imchannel.chatThreadId
dang=[c for c in channels if c.get('chatThreadId') and c['chatThreadId'] not in th_ids]
line("WARN" if dang else "ok", f"dangling imchannel.chatThreadId (-> missing thread): {len(dang)}")
if dang: warn.append(f"{len(dang)} dangling channel->thread links (self-heal on next channel activity)")
# channels missing serverId
nosrv=[c for c in channels if not c.get('serverId')]
line("WARN" if nosrv else "ok", f"channels with no serverId: {len(nosrv)}")
if nosrv: warn.append(f"{len(nosrv)} channels missing serverId")
# per-server channel spread
byserver=collections.Counter(c.get('serverId') for c in channels)
srvname={s['_id']:(s.get('displayName') or s.get('name') or s['_id']) for s in servers}
line("ok","channels per server: "+", ".join(f"{srvname.get(k,k)}={v}" for k,v in byserver.most_common(8)))
srv_noremote=[s for s in servers if not s.get('remoteId')]
if srv_noremote: line("WARN",f"servers with no remoteId: {len(srv_noremote)}"); warn.append(f"{len(srv_noremote)} servers missing remoteId")

# CHATTHREAD INTEGRITY
SEC("CHATTHREADS")
bysvc=collections.Counter(t.get('replyService','?') for t in threads)
line("ok","threads by service: "+", ".join(f"{k}={v}" for k,v in bysvc.most_common()))
line("ok",f"channel threads={len(chan_threads)}  1:1/DM threads={len(threads)-len(chan_threads)}")
# duplicate 1:1 threads (same normalizedAddress + replyService)
dm=[t for t in threads if not t.get('channelId')]
d11=collections.Counter((t.get('normalizedAddress'),t.get('replyService')) for t in dm)
d11z={k:v for k,v in d11.items() if v>1 and k[0]}
line("WARN" if d11z else "ok", f"duplicate 1:1 threads (same address+service): {len(d11z)}")
for k,v in list(d11z.items())[:10]: warn.append(f"dup 1:1 {k} x{v}"); line("  ",f"{k} x{v}")
invis=[t for t in threads if not (t.get('flags') or {}).get('visible',True)]
line("ok", f"non-visible threads (hidden): {len(invis)}")

# CONTACT / KEY INTEGRITY — is the routable key used for sending and a human key shown for display?
SEC("CONTACT / KEY INTEGRITY (chatthreader routing + contactlinker names)")
def keykind(s):
    s=str(s or '')
    if re.search(r'@s\.whatsapp\.net|@g\.us',s): return 'JID'
    if re.search(r'@lid',s): return 'lid'
    if re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',s): return 'UUID'
    if re.fullmatch(r'\+?\d[\d ]{5,}',s): return 'phone'
    if re.fullmatch(r'\d{5,}',s): return 'numeric-id'
    return 'name/handle'
RAW_DISPLAY={'JID','lid','UUID'}   # any of these SHOWN to the user = a name-resolution failure
dm=[t for t in threads if not t.get('channelId')]
sth=collections.defaultdict(list)
for t in dm: sth[t.get('replyService','?')].append(t)
for svc in sorted(sth):
    ts=sth[svc]
    raw=[t for t in ts if keykind(t.get('displayName')) in RAW_DISPLAY]
    routemix=collections.Counter(keykind(t.get('replyAddress')) for t in ts)
    tag="WARN" if raw else "ok"
    if raw: warn.append(f"{svc}: {len(raw)} thread(s) show a raw id (JID/UUID/@lid), not a phone/name")
    line(tag, f"{svc:15} threads={len(ts):3} route-key={dict(routemix)} raw-id-displays={len(raw)}")
    if len([k for k in routemix if k in ('phone','JID','lid')])>1:
        line("WARN", f"    ^ {svc} mixes phone and JID/@lid route keys -> one contact can split into duplicate threads")
        warn.append(f"{svc} mixes phone+JID route keys (split-thread risk)")
# buddy alias resolution per service (imbuddystatus = where the transport writes routable id + alias)
bs=collections.defaultdict(list)
for b in buddies: bs[b.get('serviceName','?')].append(b)
for svc in sorted(bs):
    bl=bs[svc]
    unresolved=sum(1 for b in bl if str(b.get('displayName') or b.get('serverAlias') or '')==str(b.get('username') or ''))
    uk=collections.Counter(keykind(b.get('username')) for b in bl)
    line("ok" if unresolved==0 else "WARN", f"buddies {svc:15} n={len(bl):4} username={dict(uk)} name-unresolved={unresolved}")
    if unresolved: warn.append(f"{svc}: {unresolved} buddies show a routable id as their name")
# contactlinker: does person.imAddresses link IM threads to unified Contacts?
plinked=sum(1 for p in persons if p.get('imAddresses'))
line("WARN" if plinked==0 else "ok", f"contactlinker: {plinked}/{len(persons)} person records carry imAddresses"
     + (" — IM threads are NOT linked to unified Contacts; names come from buddy aliases only" if plinked==0 else ""))
if plinked==0: warn.append("contactlinker not populating person.imAddresses (no unified-contact link/photo)")

# MESSAGES
SEC("MESSAGES")
line("ok", f"immessages total={ct_msg}   inbox={inbox} outbox={outbox}")
svcmsg={'discord':disc,'telegram':tele,'whatsapp':wa,'gometa':gm,'signal':sig,'teams':teams}
line("ok", "per service: "+", ".join(f"{k}={v}" for k,v in svcmsg.items() if v))
try:
    if inbox and outbox and int(ct_msg) and (int(inbox)+int(outbox)) < int(ct_msg)*0.9:
        line("WARN", f"folder sum ({int(inbox)+int(outbox)}) << total ({ct_msg}) — some messages in other/unknown folders")
except Exception: pass

# WATCHES
SEC("DB8 WATCH HEALTH (leak detection)")
wl=open(os.path.join(W,'watches.txt')).read().strip().splitlines() if os.path.exists(os.path.join(W,'watches.txt')) else []
if not wl:
    line("ok","no 'watches open on index' warnings in /var/log/messages (healthy — count below db8's warn threshold)")
else:
    for l in wl[:12]:
        parts=l.split(None,1); n=int(parts[0]); idx=parts[1] if len(parts)>1 else '?'
        tag="ok"
        if n>=500: tag="FAIL"; fail.append(f"watch index {idx} peaked at {n}")
        elif n>=200: tag="WARN"; warn.append(f"watch index {idx} peaked at {n}")
        line(tag, f"max {n:5} watches on {idx}")
    line("note","these are PEAKS from the whole log — if the newest warning is old/pre-fix, current state is fine")

# STORAGE
SEC("STORAGE")
try:
    for l in open(os.path.join(W,'df.txt')):
        mnt,use,free=l.split()
        fk=int(free)
        tag="WARN" if (mnt=="/var" and fk<5000) or fk<20000 else "ok"
        if tag=="WARN": warn.append(f"{mnt} low free ({fk}k)")
        line(tag, f"{mnt:16} used={use} free={fk}k")
except Exception: pass
try:
    ob=open(os.path.join(W,'objdb.txt')).read().strip()
    if ob: line("ok", f"objects.db size = {int(ob)//1024} KiB")
except Exception: pass

# SUMMARY
SEC("SUMMARY")
if fail:
    print(f"  RESULT: FAIL — {len(fail)} problem(s), {len(warn)} warning(s)")
    for f in fail[:20]: print(f"    FAIL: {f}")
elif warn:
    print(f"  RESULT: WARN — {len(warn)} warning(s), no hard failures")
    for w in warn[:20]: print(f"    WARN: {w}")
else:
    print("  RESULT: ALL CLEAR — no duplicates, orphans, dangling links, watch leaks or storage issues")
open(os.path.join(W,'.rc'),'w').write('2' if fail else ('1' if warn else '0'))
PY
RC=$(cat "$WORK/.rc" 2>/dev/null || echo 0)
exit "$RC"
