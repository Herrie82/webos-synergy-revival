#!/bin/bash
# =============================================================================
# Regression test for GH issue #3: "Two postinsts SIGTERM their own installer, aborting the whole
# Preware batch".
#
# The postinsts "nudge" cached consumers of a component to reload by killing anything whose
# /proc/<pid>/cmdline matches a fixed string. An unqualified sweep also matches whatever ran the
# postinst itself whenever the pattern is a substring of the installer's own cmdline (package id /
# ipk path) -- ApplicationInstallerUtility, ipkg, and pmPostInstall.script all carry it. Confirmed
# live for com.palm.service.contacts.linker and com.palm.messaging.chatthreader: the package
# installs correctly, then the installer is SIGTERM'd, webOS reports FAILED_IPKG_INSTALL, and
# Preware aborts the rest of the batch.
#
# The fix is the shared nudge_kill() shape (skip $$ and the whole installer/remover chain before
# matching). This test extracts the REAL nudge_kill() out of each shipped postinst that carries
# one -- this repo's packaging/generic/postinst plus the sibling app-services and chatthreader
# repos when present -- and runs it against a synthetic /proc built from the exact test matrix in
# GH issue #3. Two variants exist and both are exercised as shipped:
#   - this repo's function reads NUDGE_PROC_ROOT/NUDGE_KILL_CMD test hooks directly;
#   - the sibling repos' canonical (core-apps-PR#4-matching) function hardcodes /proc and `kill`,
#     so the test redirects the /proc glob via one deterministic sed and shadows `kill` with a
#     shell function (POSIX function lookup wins over the external command).
#
# Usage: tests/test-nudge-kill.sh
#   REPOS_ROOT overrides where the sibling repos live (default: parent of this repo).
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REPOS_ROOT="${REPOS_ROOT:-$(dirname "$REPO")}"

# label : postinst path : sweep pattern to exercise
TARGETS=(
  "synergy-generic:$REPO/packaging/generic/postinst:contacts.linker"
  "core-apps:$REPOS_ROOT/core-apps/packaging/lib/postinst:contacts.linker"
  "app-services:$REPOS_ROOT/app-services/packaging/lib/postinst:contacts.linker"
  "chatthreader:$REPOS_ROOT/com.palm.messaging.chatthreader/packaging/lib/postinst:chatthreader"
)

PASS=0; FAIL=0; SKIP=0

run_target() {
  local label="$1" postinst="$2" pat="$3"
  if [ ! -f "$postinst" ]; then
    echo "SKIP $label: $postinst not found"
    SKIP=$((SKIP + 1)); return 0
  fi

  local WORK; WORK="$(mktemp -d)"
  local PROCROOT="$WORK/proc" KILLED="$WORK/killed.log"
  : > "$KILLED"; mkdir -p "$PROCROOT"

  mkproc() { local pid="$1"; shift; mkdir -p "$PROCROOT/$pid"; printf '%s' "$*" > "$PROCROOT/$pid/cmdline"; }

  # The GH issue #3 test matrix, parameterized by the sweep pattern. Only 104 (a real consumer of
  # the swept component) may be killed; 100-103 and 106 are the installer/remover chain, 105 is an
  # unrelated process.
  local PKG="com.palm.pkg.$pat"
  mkproc 100 "sh -c /media/cryptofs/apps/.scripts/$PKG/pmPostInstall.script"
  mkproc 101 "/usr/bin/ApplicationInstallerUtility --install /media/internal/.developer/${PKG}_1.0_all.ipk"
  mkproc 102 "ipkg -o /media/cryptofs/apps -force-overwrite install /media/internal/.developer/${PKG}_1.0_all.ipk"
  mkproc 103 "sh /media/cryptofs/apps/usr/lib/ipkg/info/$PKG.postinst"
  mkproc 104 "/usr/bin/node /usr/palm/services/$PKG/jsservicelauncher/bootstrap-node.js /usr/palm/services/$PKG/services.json"
  mkproc 105 "/usr/bin/LunaSysMgr"
  mkproc 106 "sh -c /media/cryptofs/apps/.scripts/$PKG/pmPreRemove.script"

  # Extract the real shipped function -- not a reimplementation that could drift from it.
  local FUNC="$WORK/nudge_kill.sh"
  awk '/^nudge_kill\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$postinst" > "$FUNC"
  if [ ! -s "$FUNC" ]; then
    echo "FAIL $label: could not extract nudge_kill() from $postinst -- renamed/removed, or the unguarded sweep is back"
    FAIL=$((FAIL + 1)); rm -rf "$WORK"; return 0
  fi

  fake_kill() { echo "$1" >> "$KILLED"; }
  if grep -q NUDGE_PROC_ROOT "$FUNC"; then
    # Hook-carrying variant (this repo's generic/postinst).
    export NUDGE_PROC_ROOT="$PROCROOT"
    NUDGE_KILL_CMD=fake_kill
    # shellcheck disable=SC1090
    . "$FUNC"
  else
    # Canonical variant: redirect the hardcoded /proc glob, shadow `kill` with a function. Verify
    # the sed actually rewrote something -- a silent no-op here would sweep the REAL /proc.
    sed "s|/proc/\[0-9\]\*|\"$PROCROOT\"/[0-9]*|" "$FUNC" > "$FUNC.sandboxed"
    if ! grep -qF "$PROCROOT" "$FUNC.sandboxed"; then
      echo "FAIL $label: could not sandbox the /proc glob in nudge_kill() -- its loop shape changed"
      FAIL=$((FAIL + 1)); rm -rf "$WORK"; return 0
    fi
    kill() { echo "$1" >> "$KILLED"; }
    # shellcheck disable=SC1090
    . "$FUNC.sandboxed"
  fi

  # Run in-process so $$ is this test's own pid, distinct from every fabricated 10x pid -- the
  # installer-chain grep guard, not the skip-own-pid branch, must be what saves 100-103/106.
  nudge_kill "$pat"
  unset -f kill 2>/dev/null

  local ok=1 pid
  for pid in 100 101 102 103 106; do
    if grep -qx "$pid" "$KILLED"; then
      echo "  [$label] pid $pid (installer/removal chain) was killed -- should have been skipped"
      ok=0
    fi
  done
  if ! grep -qx 104 "$KILLED"; then
    echo "  [$label] pid 104 (the real swept target) was NOT killed -- sweep is too broad now"
    ok=0
  fi
  if grep -qx 105 "$KILLED"; then
    echo "  [$label] pid 105 (LunaSysMgr, unrelated) was killed -- pattern match is wrong"
    ok=0
  fi

  local killed_list; killed_list="$(tr '\n' ' ' < "$KILLED")"
  rm -rf "$WORK"
  unset NUDGE_PROC_ROOT NUDGE_KILL_CMD
  if [ "$ok" = 1 ]; then
    echo "PASS $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (killed pids: ${killed_list:-none})"
    FAIL=$((FAIL + 1))
  fi
}

for t in "${TARGETS[@]}"; do
  label="${t%%:*}"; rest="${t#*:}"
  path="${rest%:*}"; pat="${rest##*:}"
  run_target "$label" "$path" "$pat"
done

echo
echo "nudge-kill: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
