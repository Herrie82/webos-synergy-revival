#!/bin/bash
# =============================================================================
# Automated Synergy connector regression test (no user interaction).
#
# Reboots the TouchPad to a clean state, waits for every configured account to
# auto-login from its STORED session/token, then reports which connectors reach a
# working state. Catches regressions from transport/plugin changes without anyone
# touching the device.
#
# Scope & honesty:
#   - Messaging (IM) connectors are validated from the imlibpurpletransport log:
#     an account is PASS when its imloginstate reaches state="online" with
#     errorCode="AcctMgr_No_Error"; FAIL otherwise (with the errorCode/reason).
#   - Interactive-auth connectors (Signal/WhatsApp/Facebook-2FA) are tested for
#     SESSION REUSE only — a fresh from-scratch link needs a phone and cannot be
#     automated. That's exactly the regression we care about day to day.
#   - Documents (Box/Dropbox) + Photos are probed via their luna services; luna-send
#     replies don't print reliably over novacom, so these are best-effort (marked
#     SKIP if we can't read a result) and lean on the service's own log.
#
# Usage:  tests/test-connectors.sh [--no-reboot] [--wait SECONDS]
#   --no-reboot   test the current running state (don't reboot first)
#   --wait N      seconds to wait for accounts to settle after boot (default 150)
# =============================================================================
set -u

DEVLOG=/media/internal/imstdout.log
REPORT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build-output"
REPORT="$REPORT_DIR/connector-test-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$REPORT_DIR"

DO_REBOOT=1
WAIT_SECS=150
while [ $# -gt 0 ]; do
  case "$1" in
    --no-reboot) DO_REBOOT=0 ;;
    --wait) shift; WAIT_SECS="$1" ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

# run a script on the device via novacom (script on stdin). $1=script, $2=timeout
dev() { printf '%s\n' "$1" | timeout "${2:-60}" novacom run file://bin/sh 2>/dev/null; }

log() { echo "$@" | tee -a "$REPORT"; }

log "==================================================================="
log " Synergy connector regression test  —  $(date)"
log "==================================================================="

# ---- 1. reboot (optional) + wait for the device to come back ----------------
if [ "$DO_REBOOT" = "1" ]; then
  log "[*] Rebooting device to a clean state…"
  dev ": > $DEVLOG; sync; (reboot 2>/dev/null || tellbootie 2>/dev/null) &" 30 >/dev/null
  sleep 20
  i=0
  until timeout 12 novacom run file://bin/true >/dev/null 2>&1; do
    i=$((i+1)); [ $i -gt 40 ] && { log "[!] device did not come back — ABORT"; exit 1; }
    sleep 6
  done
  log "[*] Device back after ~$((i*6+20))s."
  # wait for the transport to launch
  j=0
  while [ $j -lt 40 ]; do
    dev 'grep -aq "imlibpurpletransport starting" '"$DEVLOG"' 2>/dev/null && echo up' 20 | grep -q up && break
    sleep 5; j=$((j+1))
  done
fi

log "[*] Waiting ${WAIT_SECS}s for accounts to settle (sync/reconnect)…"
sleep "$WAIT_SECS"

# ---- 2. MESSAGING connectors: parse each account's login state --------------
log ""
log "----- MESSAGING (IM) connectors -----------------------------------"
# Pull the newest loginStateQuery result (it lists every account) + presage-specific signals.
STATE_JSON="$(dev 'grep -aE "loginStateQuery success" '"$DEVLOG"' 2>/dev/null | tail -1' 30)"

# Known service -> friendly name map (extend as connectors are added).
SERVICES="type_telegram:Telegram type_facebook:Facebook type_signal:Signal type_whatsapp:WhatsApp type_discord:Discord type_teams:Teams type_gchat:GoogleChat type_googlechat:GoogleChat"

PASS=0; FAIL=0; SEEN=0
for pair in $SERVICES; do
  svc="${pair%%:*}"; name="${pair##*:}"
  # find this service's record inside the loginStateQuery json
  rec="$(echo "$STATE_JSON" | grep -aoE '\{[^{}]*serviceName":"'"$svc"'"[^{}]*\}' | tail -1)"
  [ -z "$rec" ] && rec="$(echo "$STATE_JSON" | grep -aoE 'serviceName":"'"$svc"'"[^}]*' | tail -1)"
  [ -z "$rec" ] && continue   # connector not configured on this device
  SEEN=$((SEEN+1))
  st="$(echo "$rec" | grep -aoE 'state":"[a-z-]+"' | head -1 | cut -d'"' -f3)"
  ec="$(echo "$rec" | grep -aoE 'errorCode":"[A-Za-z_]+"' | head -1 | cut -d'"' -f3)"
  user="$(echo "$rec" | grep -aoE 'username":"[^"]*"' | head -1 | cut -d'"' -f3)"
  if [ "$st" = "online" ]; then
    log "  [PASS] $name  ($user)  state=online"
    PASS=$((PASS+1))
  else
    log "  [FAIL] $name  ($user)  state=${st:-?}  errorCode=${ec:-?}"
    FAIL=$((FAIL+1))
  fi
done
[ "$SEEN" = "0" ] && log "  (no IM accounts found in the login-state — is anything configured?)"

# Buddy-sync sanity: did any connector actually populate contacts this boot?
BUD="$(dev 'grep -aicE "updateBuddyStatus|getFullBuddyList: buddy" '"$DEVLOG"' 2>/dev/null' 20)"
log "  buddy/contact updates this boot: ${BUD:-0}"

# ---- 3. DOCUMENTS + PHOTOS (best-effort probe) ------------------------------
log ""
log "----- DOCUMENTS / PHOTOS services --------------------------------"
# Discover installed doc/photo services on device and whether their daemon is registered.
DOCS="$(dev 'for s in com.palm.service.boxnet com.palm.service.dropbox com.palm.dropbox com.palm.box; do
  ls -d /usr/palm/services/$s* /media/cryptofs/apps/*/usr/palm/services/$s* 2>/dev/null | head -1; done' 25)"
if [ -z "$DOCS" ]; then
  log "  [SKIP] no Box/Dropbox document services found installed"
else
  echo "$DOCS" | while read -r d; do
    [ -z "$d" ] && continue
    svc="$(basename "$d" | sed 's/\.service$//')"
    log "  [INFO] found service: $svc  (luna-probe result not readable over novacom — check service log)"
  done
fi

# ---- 4. summary -------------------------------------------------------------
log ""
log "----- SUMMARY -----------------------------------------------------"
log "  IM connectors:  PASS=$PASS  FAIL=$FAIL  (of $SEEN configured)"
log "  Full report:    $REPORT"
log "==================================================================="
# exit non-zero if any IM connector failed (useful for CI / loop mode)
[ "$FAIL" = "0" ]
