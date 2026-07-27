#!/bin/bash
# deploy-cdav.sh — deploy the C+DAV synergy connector (org.webosports.service.cdav) to a
# stock HP webOS 3.0.5 TouchPad over novacom, integrated into Accounts & Synergy.
#
# Lays down, in the on-device layout:
#   /usr/palm/services/org.webosports.service.cdav/            the node service (+ palm_bus_config.json)
#   /usr/share/ls2/roles/{pub,prv}/org.webosports.service.cdav.json   luna-service2 roles
#   /usr/share/dbus-1/system-services/org.webosports.service.cdav.service   activation
#   /etc/palm/db/{kinds,permissions}/org.webosports.cdav.*     db8 kinds + permissions
#   /usr/palm/public/accounts/org.webosports.cdav.account*/    Accounts app templates
#   /media/cryptofs/apps/usr/palm/applications/org.webosports.app.cdav/   setup app (if built)
#
# Then registers the db kinds (owner-scoped putKind/putPermissions), rescans LS2 roles,
# tells the Accounts app to reload templates, and (re)starts the service.
#
# Usage:  ./deploy-cdav.sh [deviceid]         (default deviceid: topaz-linux)
#
# IMPORTANT: there can be TWO novacom devices attached (topaz vs mantaray). We ALWAYS pin
# -d topaz-linux so we never push to the wrong device. Override with arg 1 if needed.
set -u

DEVICE="${1:-topaz-linux}"
NOVA=(novacom -d "$DEVICE")
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # carddav/
STAGE="$(mktemp -d)"
SVCID=org.webosports.service.cdav
APPID=org.webosports.app.cdav

echo "== target device: $DEVICE =="
"${NOVA[@]}" run file:///bin/true 2>/dev/null || { echo "!! device $DEVICE not reachable (novacom -l):"; novacom -l; exit 1; }

# ---------------------------------------------------------------- stage payload
echo "== staging payload in $STAGE =="
P_SVC="$STAGE/usr/palm/services/$SVCID"
P_PUB="$STAGE/usr/share/ls2/roles/pub"
P_PRV="$STAGE/usr/share/ls2/roles/prv"
P_DBUS="$STAGE/usr/share/dbus-1/system-services"
P_DBUS_PUB="$STAGE/usr/share/dbus-1/services"
P_KINDS="$STAGE/etc/palm/db/kinds"
P_PERMS="$STAGE/etc/palm/db/permissions"
P_ACCT="$STAGE/usr/palm/public/accounts"
P_APP="$STAGE/media/cryptofs/apps/usr/palm/applications/$APPID"
mkdir -p "$P_SVC" "$P_PUB" "$P_PRV" "$P_DBUS" "$P_DBUS_PUB" "$P_KINDS" "$P_PERMS" "$P_ACCT"

# service tree (node code) + bus config
cp -r "$ROOT/service/services.json" "$ROOT/service/sources.json" "$ROOT/service/javascript" "$P_SVC/"
cp "$HERE/palm_bus_config.json" "$P_SVC/"

# ls2 roles
cp "$HERE/ls2/pub/$SVCID.json" "$P_PUB/"
cp "$HERE/ls2/prv/$SVCID.json" "$P_PRV/"

# dbus activation -- BOTH buses: system-services (private/prv hub) AND services (public/pub hub).
# luna-send defaults to the public bus, and the Accounts framework calls span both, so the
# activation file must exist in both dirs or the hub returns -1 "Message status unknown".
cp "$HERE/dbus/$SVCID.service" "$P_DBUS/"
cp "$HERE/dbus/$SVCID.service" "$P_DBUS_PUB/"

# db kinds + permissions (filenames are the kind id, no :1 suffix)
cp "$ROOT/service/configuration/db/kinds/"org.webosports.cdav.* "$P_KINDS/"
cp "$ROOT/service/configuration/db/permissions/"org.webosports.cdav.* "$P_PERMS/"

# account templates
cp -r "$HERE/accounts/"org.webosports.cdav.account* "$P_ACCT/"

# setup app (optional, only if it has been built into deploy/app)
APP_PRESENT=0
if [ -d "$HERE/app/$APPID" ]; then
	mkdir -p "$P_APP"
	cp -r "$HERE/app/$APPID/." "$P_APP/"
	APP_PRESENT=1
	echo "   including setup app $APPID"
else
	echo "   (no setup app in deploy/app/$APPID -- skipping; add via UI won't work until built)"
fi

# ---------------------------------------------------------------- push tarball
TAR="$STAGE/cdav-payload.tar"
( cd "$STAGE" && tar cf "$TAR" usr etc media 2>/dev/null || tar cf "$TAR" usr etc )
echo "== pushing payload ($(du -h "$TAR" | cut -f1)) =="
"${NOVA[@]}" put file:///tmp/cdav-payload.tar < "$TAR" || { echo "!! push failed"; rm -rf "$STAGE"; exit 1; }

# ---------------------------------------------------------------- on-device install
cp "$HERE/provision-cdav-db.sh" "$STAGE/provision-cdav-db.sh"
"${NOVA[@]}" put file:///tmp/provision-cdav-db.sh < "$HERE/provision-cdav-db.sh"

cat > "$STAGE/cdav-postinstall.sh" <<'POST'
#!/bin/sh
set -u
SVCID=org.webosports.service.cdav
echo "-- extracting payload to / --"
cd / && tar xf /tmp/cdav-payload.tar || { echo "!! extract failed"; exit 1; }
chmod +x /tmp/provision-cdav-db.sh 2>/dev/null

echo "-- provisioning db8 kinds + permissions --"
sh /tmp/provision-cdav-db.sh

echo "-- rescanning luna-service2 roles --"
ls-control scan-services 2>/dev/null || echo "   (ls-control scan-services not available)"

echo "-- telling Accounts to reload templates --"
luna-send -n 1 palm://com.palm.service.accounts/listAccountTemplates '{}' >/dev/null 2>&1
# nudge appinstaller to re-read /usr/palm/public/accounts
luna-send -n 1 palm://com.palm.appinstaller/notifyAppInstalled '{"appId":"'$SVCID'"}' >/dev/null 2>&1

echo "-- (re)starting the service --"
for p in $(ps 2>/dev/null | grep "$SVCID" | grep -v grep | awk '{print $1}'); do
	echo "   killing pid $p"; kill $p 2>/dev/null
done
# ping it to activate via dbus
luna-send -n 1 -f palm://$SVCID/checkStatus '{"accountId":"deploy-ping"}' >/dev/null 2>&1 &
sleep 4

echo "-- verify --"
echo "   service dir:   $(ls -d /usr/palm/services/$SVCID 2>&1)"
echo "   pub role:      $(ls /usr/share/ls2/roles/pub/$SVCID.json 2>&1)"
echo "   dbus service:  $(ls /usr/share/dbus-1/system-services/$SVCID.service 2>&1)"
echo "   templates:     $(ls -d /usr/palm/public/accounts/org.webosports.cdav.account* 2>&1 | tr '\n' ' ')"
echo "   kinds staged:  $(ls /etc/palm/db/kinds/org.webosports.cdav.* 2>&1 | wc -l) files"
echo "   service log tail:"
tail -n 15 /media/internal/.org.webosports.service.cdav.log 2>/dev/null | sed 's/^/     /'
POST
"${NOVA[@]}" put file:///tmp/cdav-postinstall.sh < "$STAGE/cdav-postinstall.sh"
echo "== running on-device post-install =="
"${NOVA[@]}" run file:///bin/sh -- /tmp/cdav-postinstall.sh

rm -rf "$STAGE"
echo "== done. If a template didn't appear in Accounts, restart LunaSysMgr or reboot. =="
