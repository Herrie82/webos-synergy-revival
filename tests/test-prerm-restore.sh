#!/bin/bash
# =============================================================================
# Functional regression test for GH issue #2: "Common prerm is broken" -- the shared prerm located
# its work through $OV/dest.txt, but the matching postinst deletes $OV as its own last step, so on
# any normal uninstall the prerm found nothing, skipped its whole restore block, and exited
# "success": the replaced component stayed in place forever and its backup tar was orphaned.
#
# This exercises the REAL shipped scripts (packaging/lib/{postinst,prerm}) from each sibling
# stage_whole-family repo, host-side, in a sandbox: every /media/cryptofs literal is rewritten to
# a temp dir on a COPY of the script at test time, dest.txt points inside the sandbox, and the
# scripts are invoked through .scripts/<pkg-id>/pmPostInstall.script / pmPreRemove.script paths so
# their $0-based PKGID derivation runs for real. luna-send/mount don't exist or fail harmlessly
# under the scripts' own 2>/dev/null redirections.
#
# Per family it asserts the full cycle:
#   install   -> payload applied, stock backed up, $OV wiped, .last-installed marker written
#   uninstall -> stock RESTORED from the backup via the marker fallback (the #2 fix), backup
#                consumed, marker cleared
#   uninstall AGAIN (WOSQI double-call) -> the just-restored stock is NOT deleted
#
# Usage: tests/test-prerm-restore.sh
#   REPOS_ROOT overrides where the sibling repos live (default: parent of this repo).
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REPOS_ROOT="${REPOS_ROOT:-$(dirname "$REPO")}"

# repo-dir : family-constant (as used in /media/cryptofs/<family>-overwrite|-backup)
FAMILIES="
core-apps:core-apps
app-services:app-services
com.palm.messaging.chatthreader:chatthreader
enyo-1.0:enyo
luna-systemui:luna-systemui
"

PASS=0; FAIL=0; SKIP=0

run_family() {
  local repodir="$1" fam="$2"
  local lib="$REPOS_ROOT/$repodir/packaging/lib"
  if [ ! -f "$lib/postinst" ] || [ ! -f "$lib/prerm" ]; then
    echo "SKIP $repodir: $lib/{postinst,prerm} not found"
    SKIP=$((SKIP + 1)); return 0
  fi

  local T; T="$(mktemp -d)"
  local PKGID="com.test.$fam.pkg"
  local DST="$T/root/usr/palm/services/com.test.target"

  # Sandbox the scripts: the /media/cryptofs prefix is rewritten, and the /proc process sweep is
  # pointed at an empty dir so the test never signals real host processes -- proven necessary, not
  # hypothetical: run against the PRE-fix scripts, the unguarded "chatthreader" sweep matched this
  # very test runner's cmdline and SIGTERM'd it (GH issue #3 reproducing on the host). The sweep's
  # own skip-the-installer logic is covered separately by test-nudge-kill.sh.
  mkdir -p "$T/scripts/.scripts/$PKGID" "$T/proc"
  sed -e "s|/media/cryptofs|$T/cryptofs|g" -e "s|/proc/\[0-9\]\*|$T/proc/[0-9]*|g" \
    "$lib/postinst" > "$T/scripts/.scripts/$PKGID/pmPostInstall.script"
  sed -e "s|/media/cryptofs|$T/cryptofs|g" -e "s|/proc/\[0-9\]\*|$T/proc/[0-9]*|g" \
    "$lib/prerm"    > "$T/scripts/.scripts/$PKGID/pmPreRemove.script"

  # Fake stock content at the destination.
  mkdir -p "$DST"
  echo "stock-marker" > "$DST/stock.txt"

  # Stage the package payload the way stage_whole does.
  local OV="$T/cryptofs/$fam-overwrite/$PKGID"
  mkdir -p "$OV"
  printf '%s' "$DST" > "$OV/dest.txt"
  local PAY; PAY="$(mktemp -d)"
  echo "ours-marker" > "$PAY/ours.txt"
  tar -C "$PAY" -czf "$OV/payload.tar.gz" .
  rm -rf "$PAY"

  local ok=1 out

  out="$(sh "$T/scripts/.scripts/$PKGID/pmPostInstall.script" 2>&1)"
  [ -f "$DST/ours.txt" ]      || { echo "  [$fam] install did not apply payload"; ok=0; }
  [ ! -f "$DST/stock.txt" ]   || { echo "  [$fam] install left stock content mixed in"; ok=0; }
  [ ! -d "$OV" ]              || { echo "  [$fam] install did not wipe \$OV"; ok=0; }
  local MARK="$T/cryptofs/$fam-overwrite/.last-installed/$PKGID.dest.txt"
  [ -f "$MARK" ]              || { echo "  [$fam] install did not write the .last-installed marker"; ok=0; }
  ls "$T/cryptofs/$fam-backup"* >/dev/null 2>&1 \
                              || { echo "  [$fam] install did not create a stock backup"; ok=0; }
  [ "$ok" = 1 ] || printf '%s\n' "$out" | sed 's/^/    | /'

  # The uninstall under test: $OV is gone (postinst wiped it), so only the marker fallback -- the
  # GH issue #2 fix -- can find the destination. On the pre-fix prerm this restores nothing.
  out="$(sh "$T/scripts/.scripts/$PKGID/pmPreRemove.script" 2>&1)"
  if [ ! -f "$DST/stock.txt" ]; then
    echo "  [$fam] UNINSTALL DID NOT RESTORE STOCK (GH issue #2 behavior)"; ok=0
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi
  [ ! -f "$DST/ours.txt" ]    || { echo "  [$fam] uninstall left our payload in place"; ok=0; }
  if ls "$T/cryptofs/$fam-backup"*.tar >/dev/null 2>&1; then
    echo "  [$fam] uninstall left the backup tar orphaned"; ok=0
  fi
  [ ! -f "$MARK" ]            || { echo "  [$fam] uninstall did not clear the marker"; ok=0; }

  # WOSQI double-uninstall: a second call must NOT rm -rf the stock the first call just restored.
  sh "$T/scripts/.scripts/$PKGID/pmPreRemove.script" >/dev/null 2>&1
  [ -f "$DST/stock.txt" ]     || { echo "  [$fam] SECOND uninstall deleted the restored stock"; ok=0; }

  rm -rf "$T"
  if [ "$ok" = 1 ]; then
    echo "PASS $repodir"
    PASS=$((PASS + 1))
  else
    echo "FAIL $repodir"
    FAIL=$((FAIL + 1))
  fi
}

# luna-systemui's SURGICAL mode (stage_files: files.txt + files.tar.gz, per-file patch of a shared
# directory) has its own prerm path: restore the per-file backup, remove only the files we added
# that had no prior copy. On the marker fallback (normal uninstall, $OV gone) that needs the
# files.txt copy postinst persists under .last-installed/ -- exercise that separately.
run_lunasystemui_surgical() {
  local lib="$REPOS_ROOT/luna-systemui/packaging/lib"
  if [ ! -f "$lib/postinst" ] || [ ! -f "$lib/prerm" ]; then
    echo "SKIP luna-systemui-surgical: $lib/{postinst,prerm} not found"
    SKIP=$((SKIP + 1)); return 0
  fi

  local T; T="$(mktemp -d)"
  local PKGID="com.test.lsui.surgical"
  local DST="$T/root/usr/lib/luna/system/luna-systemui"

  mkdir -p "$T/scripts/.scripts/$PKGID" "$T/proc"
  sed -e "s|/media/cryptofs|$T/cryptofs|g" -e "s|/proc/\[0-9\]\*|$T/proc/[0-9]*|g" \
    "$lib/postinst" > "$T/scripts/.scripts/$PKGID/pmPostInstall.script"
  sed -e "s|/media/cryptofs|$T/cryptofs|g" -e "s|/proc/\[0-9\]\*|$T/proc/[0-9]*|g" \
    "$lib/prerm"    > "$T/scripts/.scripts/$PKGID/pmPreRemove.script"

  # Shared stock directory: one file we will patch, one we never touch.
  mkdir -p "$DST/app"
  echo "stock-patched" > "$DST/app/Patched.js"
  echo "stock-untouched" > "$DST/app/Other.js"

  local OV="$T/cryptofs/luna-systemui-overwrite/$PKGID"
  mkdir -p "$OV"
  printf '%s' "$DST" > "$OV/dest.txt"
  printf 'app/Patched.js\napp/New.js\n' > "$OV/files.txt"
  local PAY; PAY="$(mktemp -d)"
  mkdir -p "$PAY/app"
  echo "ours-patched" > "$PAY/app/Patched.js"
  echo "ours-new" > "$PAY/app/New.js"
  tar -C "$PAY" -czf "$OV/files.tar.gz" .
  rm -rf "$PAY"

  local ok=1
  sh "$T/scripts/.scripts/$PKGID/pmPostInstall.script" >/dev/null 2>&1
  grep -q "ours-patched" "$DST/app/Patched.js" 2>/dev/null || { echo "  [lsui-surgical] install did not patch file"; ok=0; }
  [ -f "$DST/app/New.js" ]  || { echo "  [lsui-surgical] install did not add new file"; ok=0; }
  [ ! -d "$OV" ]            || { echo "  [lsui-surgical] install did not wipe \$OV"; ok=0; }

  # Normal uninstall: $OV is gone, so only the .last-installed markers can drive the restore.
  sh "$T/scripts/.scripts/$PKGID/pmPreRemove.script" >/dev/null 2>&1
  grep -q "stock-patched" "$DST/app/Patched.js" 2>/dev/null \
                            || { echo "  [lsui-surgical] UNINSTALL DID NOT RESTORE PATCHED FILE (GH issue #2 behavior)"; ok=0; }
  [ ! -f "$DST/app/New.js" ] || { echo "  [lsui-surgical] uninstall left our added file behind"; ok=0; }
  grep -q "stock-untouched" "$DST/app/Other.js" 2>/dev/null \
                            || { echo "  [lsui-surgical] uninstall damaged an unrelated file"; ok=0; }
  [ -d "$DST" ]             || { echo "  [lsui-surgical] uninstall rm -rf'd the SHARED directory"; ok=0; }

  # WOSQI double-uninstall: second call must leave the restored state alone.
  sh "$T/scripts/.scripts/$PKGID/pmPreRemove.script" >/dev/null 2>&1
  grep -q "stock-patched" "$DST/app/Patched.js" 2>/dev/null \
                            || { echo "  [lsui-surgical] SECOND uninstall damaged the restored file"; ok=0; }

  rm -rf "$T"
  if [ "$ok" = 1 ]; then
    echo "PASS luna-systemui (surgical mode)"
    PASS=$((PASS + 1))
  else
    echo "FAIL luna-systemui (surgical mode)"
    FAIL=$((FAIL + 1))
  fi
}

for entry in $FAMILIES; do
  run_family "${entry%%:*}" "${entry##*:}"
done
run_lunasystemui_surgical

echo
echo "prerm-restore: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
