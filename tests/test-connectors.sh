#!/bin/bash
# =============================================================================
# Automated Synergy connector test harness — file-driven, no user interaction.
#
# Reads an accounts file, PROVISIONS each account on the device via the accounts
# service (createAccount), waits for the connector to attempt login, and classifies
# the outcome:
#     online     — imloginstate reached state="online"  (full login worked)
#     challenge  — connector reached an interactive-auth point (QR / 2FA / pairing
#                  code was raised) — i.e. the plugin works, it just needs a human
#     error      — auth/network error or offline with an errorCode
#     timeout    — no state change (never attempted / stuck)
# Each account declares its EXPECTED outcome; PASS when actual matches (or expect=any).
#
# Accounts file (pipe-delimited, see accounts.example.tsv):
#     templateId | capabilityId | username | password | expect
#
# Usage:
#   tests/test-connectors.sh [--file PATH] [--cleanup] [--per-acct-wait SECONDS]
#     --file PATH        accounts file (default: tests/accounts.local.tsv)
#     --cleanup          deleteAccount every account this run created (leaves device clean)
#     --per-acct-wait N  seconds to wait for each account to settle (default 90)
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ACCT_FILE="$HERE/accounts.local.tsv"
CLEANUP=0
WAIT=90
DEVLOG=/media/internal/imstdout.log
REPORT="$REPO/build-output/connector-test-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$REPORT")"

while [ $# -gt 0 ]; do
  case "$1" in
    --file) shift; ACCT_FILE="$1" ;;
    --cleanup) CLEANUP=1 ;;
    --per-acct-wait) shift; WAIT="$1" ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

[ -f "$ACCT_FILE" ] || { echo "accounts file not found: $ACCT_FILE (copy accounts.example.tsv)"; exit 2; }

dev() { printf '%s\n' "$1" | timeout "${2:-60}" novacom run file://bin/sh 2>/dev/null; }
log() { echo "$@" | tee -a "$REPORT"; }

log "==================================================================="
log " Synergy connector test  —  $(date)"
log " accounts file: $ACCT_FILE"
log "==================================================================="

# Sanity: transport reachable?
if ! dev 'pgrep -f imlibpurpletransport >/dev/null 2>&1 && echo up' 20 | grep -q up; then
  log "[!] imlibpurpletransport is not running (no account online yet). Continuing — creating an"
  log "    account will dbus-activate it."
fi

PASS=0; FAIL=0; CREATED_IDS=""

# classify the login outcome for a given accountId, polling up to $WAIT seconds
classify() {
  local aid="$1" svc="$2" deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # newest imloginstate for this account
    local rec st ec
    rec="$(dev 'grep -aE "loginStateQuery success|imloginstate" '"$DEVLOG"' 2>/dev/null | grep -a "'"$aid"'" | tail -1' 25)"
    st="$(echo "$rec"  | grep -aoE 'state":"[a-z-]+"' | tail -1 | cut -d'"' -f3)"
    ec="$(echo "$rec"  | grep -aoE 'errorCode":"[A-Za-z_]+"' | tail -1 | cut -d'"' -f3)"
    if [ "$st" = "online" ]; then echo "online:$ec"; return; fi
    # interactive-auth reached? (QR/2FA/pairing raised for this service)
    if dev 'grep -aiE "adapter_request_fields: QR for service='"$svc"'|publishQRChallenge key=[^ ]*'"$svc"'|FB2FA: login-approval challenge|awaiting_2fa=1" '"$DEVLOG"' 2>/dev/null | tail -1 | grep -q .' 25; then
      echo "challenge:$ec"; return
    fi
    # hard error?
    if [ -n "$ec" ] && [ "$ec" != "AcctMgr_No_Error" ]; then echo "error:$ec"; return; fi
    if dev 'grep -aiE "loginResult:.*'"$aid"'.*noRetry=1|account_login_failed.*'"$svc"'" '"$DEVLOG"' 2>/dev/null | tail -1 | grep -q .' 25; then
      echo "error:${ec:-login_failed}"; return
    fi
    sleep 6
  done
  echo "timeout:${ec:-none}"
}

# ---- provision + test each account -----------------------------------------
while IFS='|' read -r tmpl cap user pass expect; do
  # trim + skip comments/blanks
  tmpl="$(echo "$tmpl" | sed 's/^ *//;s/ *$//')"; [ -z "$tmpl" ] && continue
  case "$tmpl" in \#*) continue;; esac
  cap="$(echo "$cap" | sed 's/^ *//;s/ *$//')"
  user="$(echo "$user" | sed 's/^ *//;s/ *$//')"
  pass="$(echo "$pass" | sed 's/^ *//;s/ *$//')"
  expect="$(echo "$expect" | sed 's/^ *//;s/ *$//')"; [ -z "$expect" ] && expect="any"

  log ""
  log "----- $tmpl  ($user) -----"

  # 1. createAccount
  payload="{\"templateId\":\"$tmpl\",\"username\":\"$user\",\"credentials\":{\"common\":{\"password\":\"$pass\"}},\"capabilityProviders\":[{\"id\":\"$cap\"}]}"
  dev "echo TESTMARKER_$tmpl >> $DEVLOG; luna-send -n 1 -a com.palm.app.accounts \"luna://com.palm.service.accounts/createAccount\" '$payload' >/dev/null 2>&1; echo done" 40 >/dev/null
  sleep 8

  # 2. resolve the accountId + serviceName the transport actually enabled
  info="$(dev 'grep -aE "accountEnabled id=.*serviceName=|getAccountInfoResult" '"$DEVLOG"' 2>/dev/null | tail -3' 25)"
  aid="$(echo "$info" | grep -aoE 'accountEnabled id=[^,]+' | tail -1 | sed 's/accountEnabled id=//')"
  svc="$(echo "$info" | grep -aoE 'serviceName=type_[a-z]+' | tail -1 | sed 's/serviceName=//')"
  if [ -z "$aid" ]; then
    log "  [FAIL] createAccount did not enable an account (payload rejected? capability wrong?)"
    FAIL=$((FAIL+1)); continue
  fi
  CREATED_IDS="$CREATED_IDS $aid"
  log "  provisioned: accountId=$aid  service=${svc:-?}"

  # 3. classify login outcome
  outcome="$(classify "$aid" "${svc:-type_unknown}")"
  state="${outcome%%:*}"; reason="${outcome##*:}"
  ok=0
  case "$expect" in
    any) ok=1 ;;
    "$state") ok=1 ;;
  esac
  if [ "$ok" = "1" ]; then
    log "  [PASS] outcome=$state  (expected=$expect${reason:+, reason=$reason})"
    PASS=$((PASS+1))
  else
    log "  [FAIL] outcome=$state  (expected=$expect${reason:+, reason=$reason})"
    FAIL=$((FAIL+1))
  fi
done < "$ACCT_FILE"

# ---- optional cleanup -------------------------------------------------------
if [ "$CLEANUP" = "1" ] && [ -n "$CREATED_IDS" ]; then
  log ""
  log "[*] Cleanup: deleting accounts created this run…"
  for aid in $CREATED_IDS; do
    dev "luna-send -n 1 -a com.palm.app.accounts \"luna://com.palm.service.accounts/deleteAccount\" '{\"accountId\":\"$aid\"}' >/dev/null 2>&1" 25 >/dev/null
    log "    deleted $aid"
  done
fi

log ""
log "----- SUMMARY -----------------------------------------------------"
log "  PASS=$PASS  FAIL=$FAIL"
log "  report: $REPORT"
log "==================================================================="
[ "$FAIL" = "0" ]
