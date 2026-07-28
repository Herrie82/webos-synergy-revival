#!/bin/bash
# Install bt-a2dp-fix on the TouchPad (topaz). Copies the daemon to /usr/sbin, installs the upstart job
# in /etc/event.d, and starts it. Rootfs is remounted rw for the copy. Idempotent.
set -e
DEV="${DEV:-topaz-linux}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== pushing daemon + upstart job to /media/internal ==="
novacom -d "$DEV" put file:///media/internal/bt-a2dp-fix.sh      < "$HERE/bt-a2dp-fix.sh"
novacom -d "$DEV" put file:///media/internal/bt-a2dp-fix.upstart < "$HERE/bt-a2dp-fix.upstart"

echo "=== installing to rootfs + starting ==="
printf '%s\n' '
mount -o remount,rw / 2>/dev/null
cp /media/internal/bt-a2dp-fix.sh /usr/sbin/bt-a2dp-fix.sh
chmod 755 /usr/sbin/bt-a2dp-fix.sh
cp /media/internal/bt-a2dp-fix.upstart /etc/event.d/bt-a2dp-fix
rm -f /media/internal/bt-a2dp-fix.sh /media/internal/bt-a2dp-fix.upstart
# kill any stray nohup instance, then (re)start via upstart (respawn = survives USB drops)
pkill -f bt-a2dp-fix.sh 2>/dev/null
stop  bt-a2dp-fix 2>/dev/null
start bt-a2dp-fix 2>/dev/null
sleep 2
echo "--- daemon running? ---"; ps -ef | grep -v grep | grep bt-a2dp-fix.sh
echo "--- installed ---"; ls -l /usr/sbin/bt-a2dp-fix.sh /etc/event.d/bt-a2dp-fix
' | novacom -d "$DEV" run file://bin/sh
echo "=== done. Tail /var/log/bt-a2dp-fix.log on device to watch it. ==="
