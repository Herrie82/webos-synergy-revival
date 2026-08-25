#!/bin/bash
# =============================================================================
# Regression test for GH issue #6 (filed on this repo; same bug tracked as core-apps issue #5):
# "postinst/prerm deadlock the installer: blocking luna-send rescan".
#
# `luna-send -n 1 luna://com.palm.applicationManager/rescan '{}'` (and the same call against
# com.palm.appinstaller) waits synchronously for one reply. Every postinst/prerm in this project
# family runs INSIDE LunaSysMgr's own request handling for the install/remove -- LunaSysMgr is the
# process that owes the reply, so a synchronous wait there is a circular wait with no timeout.
# Confirmed live: the install chain and the whole UI hang indefinitely until the blocked luna-send
# is killed by hand.
#
# Static, host-runnable check across THIS repo's packaging/ tree AND every sibling
# stage_whole-family repo present next to it (core-apps, app-services, enyo-1.0, luna-systemui,
# com.palm.messaging.chatthreader): every `luna-send -n 1` call against applicationManager or
# appinstaller in a postinst/prerm must be backgrounded, i.e. wrapped as
# `( luna-send ... & ) >/dev/null 2>&1` (or otherwise end with `&` before trailing redirections),
# not awaited inline.
#
# Usage: tests/test-postinst-no-blocking-rescan.sh
#   REPOS_ROOT overrides where the sibling repos live (default: parent of this repo).
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REPOS_ROOT="${REPOS_ROOT:-$(dirname "$REPO")}"

SCAN_DIRS=("$REPO/packaging")
for sib in core-apps app-services enyo-1.0 luna-systemui com.palm.messaging.chatthreader; do
  [ -d "$REPOS_ROOT/$sib/packaging" ] && SCAN_DIRS+=("$REPOS_ROOT/$sib/packaging")
done

FAIL=0
CHECKED=0

while IFS=: read -r file line content; do
  # Comment lines (including the fix's own explanatory comments, which quote the call) are not
  # calls.
  if printf '%s' "$content" | grep -qE '^\s*#'; then
    continue
  fi
  CHECKED=$((CHECKED + 1))
  # A blocking call is one NOT inside a backgrounded subshell `( ... & )` and not itself
  # terminated with a trailing `&` (ignoring the >/dev/null 2>&1 redirection tail).
  stripped="$(printf '%s' "$content" | sed -E 's/>\/dev\/null 2>&1//g; s/[[:space:]]+$//')"
  if printf '%s' "$content" | grep -qE '^\s*\(\s*luna-send' ; then
    continue  # already backgrounded: ( luna-send ... & ) ...
  fi
  if printf '%s' "$stripped" | grep -qE '&\s*$'; then
    continue  # bare trailing & (e.g. carddav's checkStatus ping)
  fi
  echo "BLOCKING luna-send (not backgrounded): $file:$line"
  echo "    $content"
  FAIL=$((FAIL + 1))
done < <(grep -rnE "luna-send[[:space:]]+-n[[:space:]]+1.*(applicationManager|appinstaller)" \
           "${SCAN_DIRS[@]}" --include=postinst --include=prerm)

echo
echo "scanned: ${SCAN_DIRS[*]}"
if [ "$CHECKED" -eq 0 ]; then
  echo "!! no applicationManager/appinstaller luna-send calls found at all -- test setup is stale, investigate" >&2
  exit 2
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: all $CHECKED applicationManager/appinstaller luna-send call(s) are backgrounded."
  exit 0
else
  echo "FAIL: $FAIL of $CHECKED applicationManager/appinstaller luna-send call(s) block synchronously" \
       "-- see GH issue #6. (If the failures are all in core-apps, its local checkout is behind the" \
       "merged upstream fix -- git pull there.)" >&2
  exit 1
fi
