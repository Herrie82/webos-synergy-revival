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
source "$HERE/control.env"
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"

# device-setup/QuickOffice/Photos payloads: postinst reads/executes these in custom, per-fix ways
# (not a simple 1:1 file copy), so they stay a separate staging area from the overwrite_rel() one.
# Still under /media/cryptofs, NOT /opt: /opt is on the root filesystem, which stock webOS boots
# READ-ONLY -- ipkg extracts data.tar.gz itself, before postinst ever runs and gets a chance to
# remount root rw, so anything staged directly under root fails that extraction outright
# ("Read-only file system", confirmed live). /media/cryptofs is always writable regardless of
# root's state.
#
# Deliberately NOT routed through stage_root_file/overwrite_rel() like everything else on this
# page: postinst reads this whole tree back out via a single hardcoded literal path (DS= in
# generic/postinst), not per-file through a PKG_ID-scoped OV dir, so there's no dest.txt-style
# indirection to make it doubling-proof the same way. It's still vulnerable in principle to the
# same offline-root doubling (Preware/WebOS Quick Install prepending /media/cryptofs/apps onto a
# path that already starts with media/cryptofs/...) - covered instead by generic/postinst's
# fix_doubled_apps_prefix(), which runs before any device-setup/* step reads from $DS and merges
# any doubled tree back into place first.
DS_OUT="$STAGE/media/cryptofs/synergy-revival/device-setup"

echo "== generic: imlibpurpleservice =="
IM="$REPO/messaging/imlibpurpleservice/imlibpurpleservice"
stage_root_file "$REPO/messaging/imlibpurpleservice/build-arm/imlibpurpletransport" /usr/bin/imlibpurpletransport
# /var is its own small (~60MB), always-writable partition (confirmed distinct from root even
# when root is read-only), but that only sidesteps the READ-ONLY-ROOT problem -- it does NOT make
# a direct $STAGE/var/... write immune to Preware/WebOS Quick Install's offline-root doubling
# (confirmed live: a direct write here landed at /media/cryptofs/apps/var/imwrap.sh instead of
# /var/imwrap.sh, silently leaving imlibpurpletransport's own dbus Exec= launcher missing and the
# whole transport never starting). Routed through stage_root_file like everything else now.
for f in imwrap.sh imdaemon.sh provision-im-db.sh provision-im-reactions.sh provision-person-search.sh; do
  stage_root_file "$IM/files/var/$f" "/var/$f"
done
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
# Routed through stage_root_file (overwrite_rel() OV mechanism), not written directly under
# $STAGE/$BACKEND_LIB - see stage_app's comment in packaging/lib/common.sh for why (Preware/WebOS
# Quick Install's offline-root ipkg would otherwise double-prefix a path already starting with
# "media/cryptofs/...").
# MUST be the gcc125 toolchain build, not gcc93's: imlibpurpletransport (built against gcc125,
# see messaging/imlibpurpleservice/build.sh) needs GLIBCXX_3.4.29, which gcc93's libstdc++.so.6.0.28
# does not provide ("version `GLIBCXX_3.4.29' not found", confirmed live -- transport wouldn't
# start at all). gcc93's build is a similar size (11.3MB vs gcc125's 11.6MB) so this is easy to
# get wrong silently; verify with `strings libstdc++.so.6 | grep GLIBCXX_3.4.29` if in doubt.
GXX="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/lib"
[ -f "$GXX/libstdc++.so.6.0.30" ] && stage_root_file "$GXX/libstdc++.so.6.0.30" "/$BACKEND_LIB/libstdc++.so.6"
# libnsl.so.1: needed by libpurple.so.0 itself (readelf -d), same crosstool-ng gcc125 sysroot.
GXX_SYSROOT="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/sysroot/lib"
[ -f "$GXX_SYSROOT/libnsl.so.1" ] && stage_root_file "$GXX_SYSROOT/libnsl.so.1" "/$BACKEND_LIB/libnsl.so.1"
# libtidy.so.58: needed by imlibpurpletransport itself (HTML sanitize, readelf -d confirms), built
# by device-setup's own tidy-arm build (see messaging/imlibpurpleservice/build.sh's TIDY var).
TIDY="$REPO/build-output/tidy-arm/install/lib"
[ -f "$TIDY/libtidy.so.58" ] && stage_root_file "$TIDY/libtidy.so.58" "/$BACKEND_LIB/libtidy.so.58"
# libopus.so.0/libogg.so.0: needed by imlibpurpletransport itself (readelf -d -- its own Opus voice
# note encoder, OpusEncoder.cpp), so universal regardless of which connectors end up installed.
# libopusfile.so.0: not needed by the transport itself, but shared by WhatsApp+Facebook (2
# connectors) -- simplest to also own here rather than duplicate across both. All three from the
# same WPE ARM staging dir every deploy-*.sh script already sourced from.
WPE="/home/herrie/webos/wpe/staging-glibc-252/lib"
for so in libopus.so.0 libogg.so.0 libopusfile.so.0; do
  [ -f "$WPE/$so" ] && cp -L "$WPE/$so" "/tmp/.$so.$$" && stage_root_file "/tmp/.$so.$$" "/$BACKEND_LIB/$so" && rm -f "/tmp/.$so.$$"
done

echo "== generic: synergy-glibc (the transport's ELF interpreter + matching libc) =="
# imlibpurpletransport's ELF interpreter is patched (build.sh --dynamic-linker) to
# /media/cryptofs/synergy-glibc/lib/ld-linux.so.3, and imwrap.sh puts synergy-glibc/lib FIRST on
# LD_LIBRARY_PATH so the matching libc/pthread/dl/rt load (loader<->libc are build-coupled; see
# imwrap.sh's big comment on why Atlas's own wpe-252 glibc can't substitute here - confirmed live
# SIGSEGV). This directory was, until now, never actually shipped by any package - every device
# needed it hand-provisioned once (see files/var/README-device-launch.md), and a device missing it
# crash-loops the transport with "env: can't execute .../imlibpurpletransport: No such file or
# directory" (confirmed live). The exact frozen glibc 2.23 build is the crosstool-NG gcc125
# toolchain's own sysroot -- the same one build.sh uses to LINK the transport against this
# interpreter in the first place.
#
# Curated, not the whole sysroot/lib (~56MB, 61 files): only what `readelf -d` needs from glibc
# itself, checked against BOTH the transport binary (build-arm/imlibpurpletransport) AND every
# connector's own prpl .so (they're dlopen'd by libpurple at runtime, so their NEEDED libs don't
# show up in the transport's own readelf -d at all - libutil.so.1 was missed at first for exactly
# this reason, only showing up on purple-presage/libpresage.so, Signal's plugin). Covers:
# libc/libpthread/librt/libm/libgcc_s/libutil (direct NEEDED, transport or a prpl), libdl (dlopen,
# used internally by libc/glib), and the NSS pieces real network use needs (libresolv +
# libnss_dns/libnss_files, which libc dlopen's per /etc/nsswitch.conf - not visible in readelf -d
# at all). Everything else the transport or a prpl needs either isn't glibc (libpurple/libtidy/
# libopus/libglib/libssl+libcrypto/liblunaservice/libjvm/... - system, WPE staging, or elsewhere
# in this script)
# or is already staged once into synergy-runtime above (libstdc++, libnsl) - duplicating those
# here would be dead weight, not a second copy anything actually loads from this dir.
GLIBC_SYSROOT="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/sysroot/lib"
# Routed through stage_root_file (overwrite_rel() OV mechanism), not written directly under
# $STAGE/media/cryptofs/synergy-glibc - same doubling hazard as $BACKEND_LIB/$APP_ROOT above.
# -L: dereference symlinks into real file copies (e.g. ld-linux.so.3 -> ld-2.23.so's actual bytes,
# under the ld-linux.so.3 name) - cryptofs (FUSE) rejects symlink() outright (confirmed live
# elsewhere in this repo, see stage_root_dir's comment), so a real symlink here would fail the same
# way at install time. A plain-file copy under each name works identically at runtime.
for so in ld-linux.so.3 libc.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libm.so.6 \
          libgcc_s.so.1 libresolv.so.2 libnss_dns.so.2 libnss_files.so.2 libutil.so.1; do
  if [ -e "$GLIBC_SYSROOT/$so" ]; then
    cp -L "$GLIBC_SYSROOT/$so" "/tmp/.$so.$$" && stage_root_file "/tmp/.$so.$$" "/media/cryptofs/synergy-glibc/lib/$so" && rm -f "/tmp/.$so.$$"
  else
    echo "!! synergy-glibc: $so missing from $GLIBC_SYSROOT" >&2
  fi
done

echo "== generic: cloudcore (shared by every cloud connector) =="
stage_root_dir "$REPO/cloud/cloudcore/service/_cloudcore" "/$SERVICES_ROOT/_cloudcore"
stage_app "$REPO/cloud/cloudcore/auth/com.palm.app.cloud-auth" com.palm.app.cloud-auth
bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.cloud-auth/appinfo.json"

echo "== generic: QuickOffice / Photos / DocViewer integration payloads (applied by postinst) =="
mkdir -p "$DS_OUT/quickoffice-integration" "$DS_OUT/photos-integration"
cp -r "$REPO/quickoffice-integration/." "$DS_OUT/quickoffice-integration/"
cp -r "$REPO/photos-integration/." "$DS_OUT/photos-integration/"
stage_app "$REPO/docviewer/com.palm.app.docviewer" com.palm.app.docviewer
bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.docviewer/appinfo.json"

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
