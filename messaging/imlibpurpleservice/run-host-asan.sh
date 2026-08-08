#!/bin/bash
# Run the host ASan/UBSan transport (see build-host-asan.sh) against a local LS2 hub.
#
#   ./run-host-asan.sh            start hubs if needed, run the transport for $DURATION, report
#   ./run-host-asan.sh hub        start the hubs and leave them running
#   ./run-host-asan.sh stop       stop the hubs
#   DURATION=120 ./run-host-asan.sh
#
# The transport is a daemon, so it does not exit on its own: it is run under `timeout` and the
# sanitizer output is what matters, not the exit status. 124 means it stayed up for the whole
# window, which is the good case.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
H=$REPO/build-output/host-asan
ST=$H/staging
DURATION=${DURATION:-25}

# The hub's unix socket must live somewhere SHORT. The staging default works out to
#   .../build-output/host-asan/staging/var/run/ls2/ls-hubd.private   = 110 bytes
# and sockaddr_un.sun_path holds 107. The hub silently fails to bind (it only surfaces as
# "g_io_create_watch: assertion 'channel != NULL' failed"), no socket file is ever created, and
# the client then falls back to inet and reports "Unable to connect to com.palm.hub
# (127.0.0.1:5512)" -- which points nowhere near the real cause. Both sides honour this env var.
export LS_HUB_LOCAL_SOCKET_DIRECTORY=${LS_HUB_LOCAL_SOCKET_DIRECTORY:-/tmp/ls2-hostasan}
mkdir -p "$LS_HUB_LOCAL_SOCKET_DIRECTORY"

[ -x "$H/imlibpurpletransport" ] || { echo "!! not built -- run ./build-host-asan.sh first"; exit 1; }

hub_running() { pgrep -f "$ST/usr/sbin/ls-hubd" >/dev/null 2>&1; }

stop_hubs() {
  if hub_running; then
    pkill -f "$ST/usr/sbin/ls-hubd"
    sleep 1
    rm -f "$ST/var/run/ls2"/*.pid
    echo "hubs stopped"
  else
    echo "no hubs running"
  fi
}

start_hubs() {
  hub_running && { echo "hubs already running"; return 0; }
  # Runtime directories the conf files point at. They are under the staging prefix because the
  # build passed WEBOS_INSTALL_ROOT, so nothing here touches /var.
  mkdir -p "$ST/var/run/ls2" \
           "$ST/var/palm/ls2/services/prv" "$ST/var/palm/ls2/services/pub" \
           "$ST/var/palm/ls2/roles/prv" "$ST/var/palm/ls2/roles/pub" \
           "$ST/var/palm/ls2-dev/services/prv" "$ST/var/palm/ls2-dev/services/pub" \
           "$ST/var/palm/ls2-dev/roles/prv" "$ST/var/palm/ls2-dev/roles/pub" \
           "$ST/usr/share/ls2/roles/prv" "$ST/usr/share/ls2/roles/pub" \
           "$ST/usr/share/dbus-1/system-services"
  # Security off for the dev hubs. The hub matches roles by exeName, and the host binary lives
  # at a different path than any shipped role file declares, so leaving it on only rejects us.
  # This says nothing about the device configuration -- see files/ls2 and files/sysbus for that.
  for f in private public; do
    [ -e "$ST/etc/luna-service2/ls-$f-dev.conf" ] || \
      sed 's/^Enabled=true/Enabled=false/' "$ST/etc/luna-service2/ls-$f.conf" \
        > "$ST/etc/luna-service2/ls-$f-dev.conf"
  done
  export LD_LIBRARY_PATH=$ST/usr/lib:$ST/lib
  # setsid + nohup so the hubs outlive this script's process group. Started from an
  # interactive-ish shell they otherwise get torn down with it, which shows up later as an
  # unexplained "Unable to connect to com.palm.hub" from the transport.
  setsid nohup "$ST/usr/sbin/ls-hubd" -l "$LS_HUB_LOCAL_SOCKET_DIRECTORY" \
      -c "$ST/etc/luna-service2/ls-private-dev.conf" > "$H/hub-prv.log" 2>&1 < /dev/null &
  setsid nohup "$ST/usr/sbin/ls-hubd" -p -l "$LS_HUB_LOCAL_SOCKET_DIRECTORY" \
      -c "$ST/etc/luna-service2/ls-public-dev.conf" > "$H/hub-pub.log" 2>&1 < /dev/null &
  # Wait for readiness rather than guessing -- a fixed sleep raced it. Either marker means the
  # hub has finished its role scan and is serving; which one appears varies by build.
  for _ in $(seq 30); do
    if hub_running && grep -qE "Done parsing role directories|ProcessRoleDirectories" \
         "$H/hub-prv.log" 2>/dev/null; then
      echo "hubs started"; return 0
    fi
    sleep 0.5
  done
  echo "!! hubs did not become ready"; tail -5 "$H/hub-prv.log"; exit 1
}

case "${1:-run}" in
  stop) stop_hubs; exit 0 ;;
  hub)  start_hubs; exit 0 ;;
  run)  ;;
  *)    echo "usage: $0 [run|hub|stop]"; exit 1 ;;
esac

start_hubs
rm -f "$H"/asan.* "$H/run.log"
echo "== running for ${DURATION}s"
cd "$H"
# halt_on_error=0 so one UBSan report does not end the run -- we want everything the startup
# path produces, not just the first thing.
ASAN_OPTIONS=detect_leaks=0:log_path=$H/asan \
UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0 \
  timeout "$DURATION" ./imlibpurpletransport > "$H/run.log" 2>&1 || true

echo
echo "== transport output (GStreamer noise from the host's gst plugins filtered)"
grep -v "GStreamer-CRITICAL\|^$" "$H/run.log" | grep -v "^ *#[0-9]" | head -20
echo
echo "== UBSan findings"
grep "runtime error:" "$H/run.log" | sed 's/^.*build-deps\///;s/^.*imlibpurpleservice\///' \
  | sort -u || echo "  none"
echo
echo "== ASan findings"
if ls "$H"/asan.* >/dev/null 2>&1; then head -30 "$H"/asan.*; else echo "  none"; fi
echo
echo "full log: $H/run.log   hubs: $H/hub-prv.log $H/hub-pub.log"
echo "stop the hubs with: $0 stop"
