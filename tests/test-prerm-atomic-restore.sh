#!/bin/bash
# =============================================================================
# Functional regression test for GH issue #8: "Uninstalling/Replacing Synergy Generic crashes
# LunaSysMgr". Root cause was packaging/generic/prerm's restore() doing a plain `cp backup dest`:
# that truncates and rewrites the LIVE inode in place, so every process with the file mmap'd
# (libWebKitLuna.so is mapped by exactly the three reported SIGBUS victims -- LunaSysMgr,
# WebAppMgr, BrowserServer) faults a page during the window and dies with signal 7. The fix is
# copy-to-a-same-directory-temp + atomic mv (rename), the pattern postinst's webkit-webm-mime
# step already used for the very same library. (The issue's own suspect -- the plain `umount` of
# the bind mounts -- can't produce SIGBUS at all: a non-lazy umount of a mount with live
# mappings just fails EBUSY. It's switched to `umount -l` anyway so teardown is deterministic;
# asserted statically below.)
#
# This exercises the REAL shipped packaging/generic/{prerm,postinst}, host-side, in a sandbox:
# every absolute root-fs path literal is rewritten into a temp dir on a COPY of the script at
# test time. The live-mapping victim is simulated with an open file descriptor held across the
# prerm run: rename() leaves that fd on the old inode (holder keeps reading its original
# content, exactly like a live mmap), while the old in-place cp rewrites straight through it.
#
# Usage: tests/test-prerm-atomic-restore.sh
#   GENERIC_DIR overrides where generic/{prerm,postinst} live (default: this repo's
#   packaging/generic) -- used to prove the test FAILS against the pre-fix scripts.
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GENERIC_DIR="${GENERIC_DIR:-$REPO/packaging/generic}"

PASS=0; FAIL=0

check() {  # $1 = 0/1 ok flag storage is caller's; usage: check <cond-exit> <message>
  if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else echo "  FAIL: $2"; FAIL=$((FAIL + 1)); fi
}

# --------------------------------------------------------------------- prerm restore() atomicity
run_prerm_case() {
  local prerm="$GENERIC_DIR/prerm"
  if [ ! -f "$prerm" ]; then echo "SKIP: $prerm not found"; return 0; fi

  local T; T="$(mktemp -d)"
  local PKGID="com.palm.synergy.generic"
  mkdir -p "$T/scripts/.scripts/$PKGID"

  # Sandbox the shipped prerm: rewrite every absolute path family it touches into $T, and neuter
  # the two host-dangerous root remount lines (everything else -- stop/umount/rmdir -- either
  # operates on rewritten paths or fails harmlessly under the script's own 2>/dev/null).
  sed -e "s|/usr/|$T/root/usr/|g" \
      -e "s|/media/|$T/root/media/|g" \
      -e "s|/var/|$T/root/var/|g" \
      -e "s|/etc/|$T/root/etc/|g" \
      -e "s|^mount -o remount|true mount -o remount|" \
      "$prerm" > "$T/scripts/.scripts/$PKGID/pmPreRemove.script"

  # Fake a patched, installed device: live (patched) files + the backups postinst made.
  mkdir -p "$T/root/usr/lib" "$T/root/usr/bin" "$T/root/usr/share/fonts" "$T/root/media/internal" \
           "$T/root/usr/palm/lib"
  echo "patched-webkit" > "$T/root/usr/lib/libWebKitLuna.so"
  echo "stock-webkit"   > "$T/root/media/internal/libWebKitLuna.so.prewebm"
  echo "thai-font"      > "$T/root/usr/share/fonts/HeiT_nb.ttf"
  echo "stock-font"     > "$T/root/usr/share/fonts/HeiT_nb.ttf.orig"
  echo "patched-bt"     > "$T/root/usr/bin/PmBtEngine"
  echo "stock-bt"       > "$T/root/usr/bin/PmBtEngine.orig"
  # NOTE: no $T/root/usr/palm/lib/libWebKitLuna.so -- stock devices only have the /usr/lib copy,
  # and restore must NOT conjure a 12.8MB duplicate onto the tiny root partition.

  # The "live mapping": hold fds open across the prerm run. rename() must leave these holders on
  # the old inode; the pre-fix in-place cp rewrites the content straight under them.
  exec 3< "$T/root/usr/lib/libWebKitLuna.so"
  exec 4< "$T/root/usr/share/fonts/HeiT_nb.ttf"

  sh "$T/scripts/.scripts/$PKGID/pmPreRemove.script" >/dev/null 2>&1

  [ "$(cat "$T/root/usr/lib/libWebKitLuna.so")" = "stock-webkit" ]
  check $? "prerm did not restore stock libWebKitLuna.so"
  [ "$(cat <&3)" = "patched-webkit" ]
  check $? "restore REWROTE the live libWebKitLuna.so inode in place (GH issue #8 SIGBUS behavior)"
  [ "$(cat "$T/root/usr/share/fonts/HeiT_nb.ttf")" = "stock-font" ]
  check $? "prerm did not restore the stock font"
  [ "$(cat <&4)" = "thai-font" ]
  check $? "restore REWROTE the live font inode in place (GH issue #8 SIGBUS behavior)"
  [ "$(cat "$T/root/usr/bin/PmBtEngine")" = "stock-bt" ]
  check $? "prerm did not restore stock PmBtEngine"
  [ ! -e "$T/root/usr/palm/lib/libWebKitLuna.so" ]
  check $? "restore CREATED a spurious /usr/palm/lib/libWebKitLuna.so on the root partition"
  ! ls "$T/root/usr/lib/"*.synergy-restore.* "$T/root/usr/share/fonts/"*.synergy-restore.* >/dev/null 2>&1
  check $? "restore left temp files behind"

  exec 3<&- 4<&-
  rm -rf "$T"
}

# --------------------------------------------------------------- prerm bind-mount teardown: -l
run_umount_case() {
  local prerm="$GENERIC_DIR/prerm"
  if [ ! -f "$prerm" ]; then echo "SKIP: $prerm not found"; return 0; fi
  # Static: both bind-mount teardown lines must use lazy detach (MNT_DETACH keeps any straggler's
  # mappings valid; plain umount just fails EBUSY and strands the mountpoint).
  [ "$(grep -c '^umount -l /usr/lib/' "$prerm")" -eq 2 ]
  check $? "prerm bind-mount teardown does not use umount -l on both mounts"
}

# ------------------------------------------------------------------- postinst atomic_cp()
run_postinst_case() {
  local postinst="$GENERIC_DIR/postinst"
  if [ ! -f "$postinst" ]; then echo "SKIP: $postinst not found"; return 0; fi

  # The install/upgrade side of the same bug: the Thai-font and gst-plugin copies land on
  # live-mmap'd destinations too. They must route through atomic_cp() ...
  grep -q 'atomic_cp "$DS/fonts/NotoSansThai-Regular.ttf"' "$postinst"
  check $? "postinst font install does not use atomic_cp (in-place cp over a live-mapped font)"

  # ... and atomic_cp itself must behave: run the REAL function extracted from the shipped
  # script (same approach as test-nudge-kill.sh) against an fd-held destination.
  local T; T="$(mktemp -d)"
  sed -n '/^atomic_cp() {/,/^}/p' "$postinst" > "$T/fn.sh"
  if [ ! -s "$T/fn.sh" ]; then
    check 1 "postinst does not define atomic_cp()"
    rm -rf "$T"; return 0
  fi
  echo "new-content" > "$T/src"
  echo "old-content" > "$T/dst"
  exec 5< "$T/dst"
  ( . "$T/fn.sh"; atomic_cp "$T/src" "$T/dst" )
  [ "$(cat "$T/dst")" = "new-content" ]
  check $? "atomic_cp did not install the new content"
  [ "$(cat <&5)" = "old-content" ]
  check $? "atomic_cp REWROTE the live destination inode in place"
  exec 5<&-
  # Identical content again -> must short-circuit without touching the inode.
  local ino1 ino2
  ino1="$(stat -c %i "$T/dst")"
  ( . "$T/fn.sh"; atomic_cp "$T/src" "$T/dst" )
  ino2="$(stat -c %i "$T/dst")"
  [ "$ino1" = "$ino2" ]
  check $? "atomic_cp churned the inode on identical content"
  rm -rf "$T"
}

run_prerm_case
run_umount_case
run_postinst_case

echo
echo "prerm-atomic-restore: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
