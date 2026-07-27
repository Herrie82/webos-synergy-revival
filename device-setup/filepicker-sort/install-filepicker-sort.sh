#!/bin/sh
# install-filepicker-sort.sh - make the system FilePicker (attach-image dialog) list album pictures
# NEWEST-first instead of oldest-first, so recent Screen captures appear at the top.
#
# The only change is one line in the stock luna-systemui FilePicker's AlbumGridView.dbQuery():
# `inQuery.desc = true;` (the album records' createdTime is 0, so we reverse the index scan by _id -
# newest capture == newest _id). Run this ON THE DEVICE (novacom run) after pushing AlbumGridView.js
# to /tmp. Idempotent; keeps a .orig backup.
set -e

FP=/usr/lib/luna/system/luna-systemui/app/FilePicker
SRC=/tmp/AlbumGridView.js   # the patched file, pushed here first

[ -f "$SRC" ] || { echo "ERROR: push AlbumGridView.js to $SRC first"; exit 1; }

mount -o remount,rw /dev/mapper/store-root / 2>/dev/null || true
[ -f "$FP/AlbumGridView.js.orig" ] || cp "$FP/AlbumGridView.js" "$FP/AlbumGridView.js.orig"
cp "$SRC" "$FP/AlbumGridView.js"
chmod 644 "$FP/AlbumGridView.js"
mount -o remount,ro /dev/mapper/store-root / 2>/dev/null || true

echo "installed newest-first FilePicker sort. Restart the UI to load it:"
echo "  stop LunaSysMgr; start LunaSysMgr"
