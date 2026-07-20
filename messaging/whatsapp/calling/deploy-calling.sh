#!/bin/bash
# deploy-calling.sh — install WhatsApp *calling* into the stock Phone app (com.palm.app.phone)
# on the connected TouchPad via novacom. This is the phone-app side of WhatsApp calling: it
# repurposes the dead Skype PHONE slot so the stock CallSynergizer/DialProxy drive the wacallm
# mediator (LS2 service com.palm.whatsapp) with zero new UI. See README.md for the full picture.
#
# Prereqs NOT handled here (see README):
#   1. wacallm mediator built + running   (build-output/wacallm-luna, LS2 role/.service)
#   2. WhatsApp account granted PHONE      (com.palm.service.accounts/modifyAccount, README "Account")
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
# novacom word-splits `sh -c "cmd"`, so pipe the command string on stdin instead of using -c.
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }

APP=/usr/palm/applications/com.palm.app.phone
SRC="$PKG/app-patches/com.palm.app.phone"

echo "== remount rootfs rw =="
nr "mount -o remount,rw /dev/mapper/store-root / || mount -o remount,rw /"

echo "== push patched phone-app files =="
for rel in \
  source/CallSynergizer.js \
  source/DialProxy.js \
  source/utils/Utils.js \
  phoneApp/source/AppMenu.js \
  phoneApp/source/CallLogView.js \
  phoneApp/source/SubItems.js \
  phoneApp/source/styles-overrides.css \
  resources/en.json ; do
  echo "   -> $rel"
  novacom put "file://$APP/$rel" < "$SRC/$rel"
done

echo "== remount rootfs ro =="
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== restart LunaSysMgr (reloads the phone app; CallSynergizer re-subscribes to wacallm) =="
nr "stop LunaSysMgr || true ; start LunaSysMgr"

echo "Done. Test: Phone app -> dial a WhatsApp number, end the call, check the Call Log tab."
