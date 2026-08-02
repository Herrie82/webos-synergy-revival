#!/bin/bash
# stage.sh — assemble the "generic" package: everything every connector depends on.
#   - imlibpurpleservice (transport binary, launch chain, db8 kinds/perms, ls2 roles)
#   - the shared libpurple 2.14 + ssl-openssl engine, overwriting the real stock
#     /usr/lib(+/purple-2) -- see packaging/README.md "why /usr/lib now"
#   - _cloudcore + com.palm.app.cloud-auth (shared by every cloud connector)
#   - quickoffice-integration / photos-integration / docviewer app
#   - device-setup/* fixes (payload files only; the patch/copy logic lives in postinst)
#
# Usage: stage.sh <stage-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$1"
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"

DS_OUT="$STAGE/opt/synergy-revival/device-setup"
# Neutral staging area for files that OVERWRITE real stock rootfs paths: postinst backs up
# whatever's already at the real destination (to /media/cryptofs/synergy-stock-backup/...) before copying
# these into place -- ipkg's own data.tar.gz unpack happens BEFORE postinst runs, so anything
# placed directly at its final path here would silently clobber stock with no chance to back it
# up first. See generic/postinst.
OVERWRITE="$STAGE/opt/synergy-revival/rootfs-overwrite"

echo "== generic: imlibpurpleservice =="
IM="$REPO/messaging/imlibpurpleservice/imlibpurpleservice"
mkdir -p "$STAGE/usr/bin"
cp "$REPO/messaging/imlibpurpleservice/build-arm/imlibpurpletransport" "$STAGE/usr/bin/imlibpurpletransport"
mkdir -p "$STAGE/var" "$STAGE/etc/event.d"
cp "$IM/files/var/imwrap.sh" "$IM/files/var/imdaemon.sh" \
   "$IM/files/var/provision-im-db.sh" "$IM/files/var/provision-im-reactions.sh" \
   "$IM/files/var/provision-person-search.sh" "$STAGE/var/"
cp "$IM/files/etc/event.d/imtransport" "$STAGE/etc/event.d/imtransport"
mkdir -p "$STAGE/etc/palm/db/kinds" "$STAGE/etc/palm/db/permissions"
cp "$IM/files/etc/palm/db/kinds/"* "$STAGE/etc/palm/db/kinds/"
cp "$IM/files/etc/palm/db/permissions/"* "$STAGE/etc/palm/db/permissions/"
mkdir -p "$STAGE/etc/palm/tempdb/kinds" "$STAGE/etc/palm/tempdb/permissions"
cp "$IM/files/etc/palm/tempdb/kinds/"* "$STAGE/etc/palm/tempdb/kinds/"
cp "$IM/files/etc/palm/tempdb/permissions/"* "$STAGE/etc/palm/tempdb/permissions/"
mkdir -p "$STAGE/etc/palm/activities/com.palm.imlibpurple"
cp "$IM/files/etc/palm/activities/com.palm.imlibpurple/"* "$STAGE/etc/palm/activities/com.palm.imlibpurple/"
mkdir -p "$STAGE/usr/share/ls2/roles/prv" "$STAGE/usr/share/ls2/roles/pub"
cp "$IM/files/ls2/roles/prv/com.palm.imlibpurple.json" "$STAGE/usr/share/ls2/roles/prv/"
cp "$IM/files/ls2/roles/pub/com.palm.imlibpurple.json" "$STAGE/usr/share/ls2/roles/pub/"
# contacts search-by-service: person kind index patch (etc/palm/db/kinds/com.palm.person above
# already overrides the stock kind with the searchProperty patch; the app-side patches.js half
# lives in the core-apps repo's com.palm.app.contacts checkout, not here — see
# messaging/imlibpurpleservice/imlibpurpleservice/files/var/README-device-launch.md)

# com.palm.imlibpurple.service: stock ships this pointed straight at the raw transport binary
# (Exec=/usr/bin/imlibpurpletransport), which bypasses imwrap.sh entirely -- no wpe-glibc loader
# patch, no SSL override, no PmLog semaphore self-heal, no ALSA preload. On-demand LS2 activation
# via this file with the stock Exec line would launch an effectively broken transport. This
# overwrites real stock (cross-checked against StockRootfs + the live device, where it had already
# been hand-fixed the same way, confirming the need) -- stage it in the neutral overwrite dir so
# postinst backs up stock first, same as libpurple.so.
mkdir -p "$OVERWRITE/dbus-1/system-services"
cp "$IM/files/dbus-1/system-services/com.palm.imlibpurple.service" "$OVERWRITE/dbus-1/system-services/"

echo "== generic: shared libpurple 2.14 + ssl-openssl engine (overwrites real /usr/lib) =="
# libpurple.so.0.14.13 here has its 3 compiled-in absolute paths (plugin dir, sysconfdir,
# datadir) binary-patched from the old com.palm.app.teams (renamed org.webosports.app.teams)/backend nesting to the real /usr/lib
# locations (/usr/lib/purple-2, /etc, /usr/share) -- same technique as the existing
# device-setup/webkit-webm-mime string patch. This is genuine stock Palm IM infrastructure
# (com.palm.imlibpurple) being modernized in place, so it's staged to OVERWRITE (postinst backs up
# whatever's already there first) rather than live in a private/app-nested location.
LP="$REPO/messaging/libpurple/lib"
mkdir -p "$OVERWRITE/lib/purple-2"
cp "$LP/libpurple.so.0.14.13" "$OVERWRITE/lib/libpurple.so.0.14.13"
ln -sf libpurple.so.0.14.13 "$OVERWRITE/lib/libpurple.so.0"
ln -sf libpurple.so.0.14.13 "$OVERWRITE/lib/libpurple.so"
# stock libpurple plugins only (NOT the stale libdiscord.so/libteams.so/libtelegram.so vendored
# copies in this checkout — each connector's own package ships its current build instead).
for so in autoaccept.so buddynote.so idle.so joinpart.so log_reader.so newline.so offlinemsg.so \
          psychic.so ssl.so ssl-openssl.so statenotify.so; do
  [ -f "$LP/purple-2/$so" ] && cp "$LP/purple-2/$so" "$OVERWRITE/lib/purple-2/$so"
done

echo "== generic: private runtime deps (non-stock-colliding, direct install) =="
# Third-party link deps unique to specific prpls -- kept OUT of /usr/lib so they can't silently
# replace a system-wide lib version other apps rely on (unlike libpurple.so itself above, this
# isn't "the same component being modernized", just an incidental dependency). imwrap.sh's
# LD_PRELOAD/LD_LIBRARY_PATH points at this dir.
mkdir -p "$STAGE/$BACKEND_LIB"
GXX="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc93/arm-unknown-linux-gnueabi/lib"
[ -f "$GXX/libstdc++.so.6.0.28" ] && cp "$GXX/libstdc++.so.6.0.28" "$STAGE/$BACKEND_LIB/libstdc++.so.6"

echo "== generic: cloudcore (shared by every cloud connector) =="
mkdir -p "$STAGE/$SERVICES_ROOT/_cloudcore"
cp -r "$REPO/cloud/cloudcore/service/_cloudcore/." "$STAGE/$SERVICES_ROOT/_cloudcore/"
stage_app "$REPO/cloud/cloudcore/auth/com.palm.app.cloud-auth" com.palm.app.cloud-auth
bump_version "$STAGE/$APP_ROOT/com.palm.app.cloud-auth/appinfo.json"

echo "== generic: QuickOffice / Photos / DocViewer integration payloads (applied by postinst) =="
mkdir -p "$DS_OUT/quickoffice-integration" "$DS_OUT/photos-integration"
cp -r "$REPO/quickoffice-integration/." "$DS_OUT/quickoffice-integration/"
cp -r "$REPO/photos-integration/." "$DS_OUT/photos-integration/"
stage_app "$REPO/docviewer/com.palm.app.docviewer" com.palm.app.docviewer
bump_version "$STAGE/$APP_ROOT/com.palm.app.docviewer/appinfo.json"

echo "== generic: device-setup/* fixes (payloads staged; postinst applies them) =="
mkdir -p "$DS_OUT"
for d in account-keepdata bt-a2dp-fix chatthreader-groupname-guard chatthreader-person-link-fix \
         contacts-messaging-guard db8-maintenance filepicker-sort fonts gst-opus-codec \
         gst-plugins-base-audioresample gst-video-codecs linker-parallel-reads videoplayer-webm \
         whatsapp-e164-normalization; do
  mkdir -p "$DS_OUT/$d"
  cp -r "$REPO/device-setup/$d/." "$DS_OUT/$d/"
done

echo "generic stage complete: $STAGE"
