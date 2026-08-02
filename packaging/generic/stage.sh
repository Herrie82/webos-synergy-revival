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
NAME=generic
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"

# device-setup/QuickOffice/Photos payloads: postinst reads/executes these in custom, per-fix ways
# (not a simple 1:1 file copy), so they stay a separate staging area from the overwrite_rel() one.
# Still under /media/cryptofs, NOT /opt: /opt is on the root filesystem, which stock webOS boots
# READ-ONLY -- ipkg extracts data.tar.gz itself, before postinst ever runs and gets a chance to
# remount root rw, so anything staged directly under root fails that extraction outright
# ("Read-only file system", confirmed live). /media/cryptofs is always writable regardless of
# root's state.
DS_OUT="$STAGE/media/cryptofs/synergy-revival/device-setup"

echo "== generic: imlibpurpleservice =="
IM="$REPO/messaging/imlibpurpleservice/imlibpurpleservice"
stage_root_file "$REPO/messaging/imlibpurpleservice/build-arm/imlibpurpletransport" /usr/bin/imlibpurpletransport
# /var is its own small (~60MB), always-writable partition (confirmed distinct from root even
# when root is read-only) -- these tiny shell scripts stage directly here as before, no OVERWRITE
# indirection needed. Keep it that way; /var is too small to also route bulkier payloads through.
mkdir -p "$STAGE/var"
cp "$IM/files/var/imwrap.sh" "$IM/files/var/imdaemon.sh" \
   "$IM/files/var/provision-im-db.sh" "$IM/files/var/provision-im-reactions.sh" \
   "$IM/files/var/provision-person-search.sh" "$STAGE/var/"
stage_root_file "$IM/files/etc/event.d/imtransport" /etc/event.d/imtransport
# ONLY the genuinely-new kind/permission names -- confirmed live on a real device (ipkg return 22)
# that com.palm.imcommand/imgroupchat/iminvitation/immessage/imloginstate (+ tempdb imbuddystatus)
# are already owned by the STOCK com.palm.messaging.chatthreader package. Shipping them in
# data.tar.gz makes ipkg refuse the ENTIRE install with "file already provided by package
# com.palm.messaging.chatthreader" -- this isn't a private/app-nested file, ipkg polices real
# system paths against its own install database. We don't need to ship them at all:
# provision-im-db.sh (below) globs whatever's ALREADY on disk (stock's copy) and re-registers it
# under its own declared "owner" field regardless of which package put it there.
for k in com.palm.config.libpurple com.palm.contact.libpurple com.palm.imchannel \
         com.palm.imcommand.libpurple com.palm.imloginstate.libpurple com.palm.immessage.libpurple \
         com.palm.imretaineddata com.palm.imserver; do
  stage_root_file "$IM/files/etc/palm/db/kinds/$k" "/etc/palm/db/kinds/$k"
done
for p in com.palm.config.libpurple com.palm.contact.libpurple com.palm.imchannel \
         com.palm.imcommand.libpurple com.palm.imloginstate.libpurple com.palm.immessage.libpurple \
         com.palm.imretaineddata com.palm.imserver; do
  stage_root_file "$IM/files/etc/palm/db/permissions/$p" "/etc/palm/db/permissions/$p"
done
stage_root_file "$IM/files/etc/palm/tempdb/kinds/com.palm.imbuddystatus.libpurple" \
  /etc/palm/tempdb/kinds/com.palm.imbuddystatus.libpurple
stage_root_dir "$IM/files/etc/palm/activities/com.palm.imlibpurple" /etc/palm/activities/com.palm.imlibpurple
stage_root_file "$IM/files/ls2/roles/prv/com.palm.imlibpurple.json" /usr/share/ls2/roles/prv/com.palm.imlibpurple.json
stage_root_file "$IM/files/ls2/roles/pub/com.palm.imlibpurple.json" /usr/share/ls2/roles/pub/com.palm.imlibpurple.json
# contacts search-by-service, part 1: the patched com.palm.person kind (adds ims.type to
# searchProperty). This one IS stock-owned (com.palm.service.contacts.linker) AND we genuinely
# need our patched content in it -- same problem as libpurple.so, same fix: stage it in the
# neutral overwrite dir so postinst backs up stock's copy before writing ours (a raw `cp` in a
# postinst script is invisible to ipkg's ownership tracking; only data.tar.gz's own manifest is
# policed). The app-side patches.js half (part 2) lives in the core-apps repo's
# com.palm.app.contacts checkout, not here — see
# messaging/imlibpurpleservice/imlibpurpleservice/files/var/README-device-launch.md
stage_root_file "$IM/files/etc/palm/db/kinds/com.palm.person" /etc/palm/db/kinds/com.palm.person

# com.palm.imlibpurple.service: stock ships this pointed straight at the raw transport binary
# (Exec=/usr/bin/imlibpurpletransport), which bypasses imwrap.sh entirely -- no wpe-glibc loader
# patch, no SSL override, no PmLog semaphore self-heal, no ALSA preload. On-demand LS2 activation
# via this file with the stock Exec line would launch an effectively broken transport. This
# overwrites real stock (cross-checked against StockRootfs + the live device, where it had already
# been hand-fixed the same way, confirming the need) -- stage it in the neutral overwrite dir so
# postinst backs up stock first, same as libpurple.so.
stage_root_file "$IM/files/dbus-1/system-services/com.palm.imlibpurple.service" \
  /usr/share/dbus-1/system-services/com.palm.imlibpurple.service

echo "== generic: shared libpurple 2.14 + ssl-openssl engine (overwrites real /usr/lib) =="
# libpurple.so.0.14.13 here has its 3 compiled-in absolute paths (plugin dir, sysconfdir,
# datadir) binary-patched from the old com.palm.app.teams (renamed org.webosports.app.teams)/backend nesting to the real /usr/lib
# locations (/usr/lib/purple-2, /etc, /usr/share) -- same technique as the existing
# device-setup/webkit-webm-mime string patch. This is genuine stock Palm IM infrastructure
# (com.palm.imlibpurple) being modernized in place, so it's staged to OVERWRITE (postinst backs up
# whatever's already there first) rather than live in a private/app-nested location.
LP="$REPO/messaging/libpurple/lib"
stage_root_file "$LP/libpurple.so.0.14.13" /usr/lib/libpurple.so.0.14.13
# libpurple.so.0 / libpurple.so are symlinks -> libpurple.so.0.14.13. NOT staged as filesystem
# symlinks at all (even via stage_root_dir's symlink-manifest trick) -- simplest to just record
# the two, well-known targets directly; apply_rootfs_overwrite() in postinst recreates them with
# a real ln -s once libpurple.so.0.14.13 itself is in place.
{
  echo "/usr/lib/libpurple.so.0	libpurple.so.0.14.13"
  echo "/usr/lib/libpurple.so	libpurple.so.0.14.13"
} >> "$STAGE/$(overwrite_rel)/.symlinks"
# stock libpurple plugins only (NOT the stale libdiscord.so/libteams.so/libtelegram.so vendored
# copies in this checkout — each connector's own package ships its current build instead).
for so in autoaccept.so buddynote.so idle.so joinpart.so log_reader.so newline.so offlinemsg.so \
          psychic.so ssl.so ssl-openssl.so statenotify.so; do
  [ -f "$LP/purple-2/$so" ] && stage_root_file "$LP/purple-2/$so" "/usr/lib/purple-2/$so"
done

echo "== generic: private runtime deps (non-stock-colliding, direct install) =="
# Third-party link deps -- kept OUT of /usr/lib so they can't silently replace a system-wide lib
# version other apps rely on (unlike libpurple.so itself above, this isn't "the same component
# being modernized", just an incidental dependency). imwrap.sh's LD_PRELOAD/LD_LIBRARY_PATH points
# at this dir. Deliberately staged HERE, not per-connector: verified with `readelf -d` that
# libtidy/libopus/libogg/libnsl are needed by the transport binary (or libpurple.so.0) itself --
# universal regardless of which connectors end up installed -- and libopusfile is shared by
# WhatsApp+Facebook. Every connector package hard-depends on generic (PKG_DEPENDS), so there's
# nothing to gain from also carrying a defensive copy there; worse, ipkg treats two packages
# shipping the same tracked filename as a hard conflict (confirmed live installing telegram then
# whatsapp when both carried their own libopus.so.0 -- this is the actual fix for that).
# Already on cryptofs (BACKEND_LIB), no OVERWRITE indirection needed for anything in this block.
mkdir -p "$STAGE/$BACKEND_LIB"
# MUST be the gcc125 toolchain build, not gcc93's: imlibpurpletransport (built against gcc125,
# see messaging/imlibpurpleservice/build.sh) needs GLIBCXX_3.4.29, which gcc93's libstdc++.so.6.0.28
# does not provide ("version `GLIBCXX_3.4.29' not found", confirmed live -- transport wouldn't
# start at all). gcc93's build is a similar size (11.3MB vs gcc125's 11.6MB) so this is easy to
# get wrong silently; verify with `strings libstdc++.so.6 | grep GLIBCXX_3.4.29` if in doubt.
GXX="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/lib"
[ -f "$GXX/libstdc++.so.6.0.30" ] && cp "$GXX/libstdc++.so.6.0.30" "$STAGE/$BACKEND_LIB/libstdc++.so.6"
# libnsl.so.1: needed by libpurple.so.0 itself (readelf -d), same crosstool-ng gcc125 sysroot.
GXX_SYSROOT="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/sysroot/lib"
[ -f "$GXX_SYSROOT/libnsl.so.1" ] && cp "$GXX_SYSROOT/libnsl.so.1" "$STAGE/$BACKEND_LIB/libnsl.so.1"
# libtidy.so.58: needed by imlibpurpletransport itself (HTML sanitize, readelf -d confirms), built
# by device-setup's own tidy-arm build (see messaging/imlibpurpleservice/build.sh's TIDY var).
TIDY="$REPO/build-output/tidy-arm/install/lib"
[ -f "$TIDY/libtidy.so.58" ] && cp "$TIDY/libtidy.so.58" "$STAGE/$BACKEND_LIB/libtidy.so.58"
# libopus.so.0/libogg.so.0: needed by imlibpurpletransport itself (readelf -d -- its own Opus voice
# note encoder, OpusEncoder.cpp), so universal regardless of which connectors get installed.
# libopusfile.so.0: not needed by the transport itself, but shared by WhatsApp+Facebook (2
# connectors) -- simplest to also own here rather than duplicate across both. All three from the
# same WPE ARM staging dir every deploy-*.sh script already sourced from.
WPE="/home/herrie/webos/wpe/staging-glibc-252/lib"
for so in libopus.so.0 libogg.so.0 libopusfile.so.0; do
  [ -f "$WPE/$so" ] && cp -L "$WPE/$so" "$STAGE/$BACKEND_LIB/$so"
done

echo "== generic: cloudcore (shared by every cloud connector) =="
stage_root_dir "$REPO/cloud/cloudcore/service/_cloudcore" "/$SERVICES_ROOT/_cloudcore"
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
for d in bt-a2dp-fix \
         db8-maintenance fonts gst-opus-codec \
         gst-plugins-base-audioresample gst-video-codecs videoplayer-webm \
         whatsapp-e164-normalization; do
  mkdir -p "$DS_OUT/$d"
  cp -r "$REPO/device-setup/$d/." "$DS_OUT/$d/"
done

echo "generic stage complete: $STAGE"
