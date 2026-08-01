#!/bin/bash
# stage.sh — assemble the "generic" package: everything every connector depends on.
#   - imlibpurpleservice (transport binary, launch chain, db8 kinds/perms, ls2 roles)
#   - the shared libpurple 2.14 + ssl-openssl backend engine (nested under com.palm.app.teams's
#     own app dir on purpose — see packaging/README.md "why com.palm.app.teams")
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

echo "== generic: shared libpurple 2.14 + ssl-openssl backend (com.palm.app.teams/backend) =="
# Physically nested under com.palm.app.teams for historical reasons (imwrap.sh and every
# connector's plugin drop-in hardcode this path) — see packaging/README.md. Generic owns ONLY
# the backend/ subtree; Teams' own package owns the app's top-level setup-app files (appinfo.json
# etc). ipkg allows multiple packages to share a directory as long as no two own the same file.
LP="$REPO/messaging/libpurple/lib"
mkdir -p "$STAGE/$APP_ROOT/com.palm.app.teams/backend/lib/purple-2"
cp "$LP/libpurple.so.0.14.13" "$STAGE/$APP_ROOT/com.palm.app.teams/backend/lib/libpurple.so.0.14.13"
ln -sf libpurple.so.0.14.13 "$STAGE/$APP_ROOT/com.palm.app.teams/backend/lib/libpurple.so.0"
ln -sf libpurple.so.0.14.13 "$STAGE/$APP_ROOT/com.palm.app.teams/backend/lib/libpurple.so"
# stock libpurple plugins only (NOT the stale libdiscord.so/libteams.so/libtelegram.so vendored
# copies in this checkout — each connector's own package ships its current build instead).
for so in autoaccept.so buddynote.so idle.so joinpart.so log_reader.so newline.so offlinemsg.so \
          psychic.so ssl.so ssl-openssl.so statenotify.so; do
  [ -f "$LP/purple-2/$so" ] && cp "$LP/purple-2/$so" "$STAGE/$APP_ROOT/com.palm.app.teams/backend/lib/purple-2/$so"
done

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
