#!/bin/bash
# build-all.sh — stage + package every connector into packaging/out/*.ipk.
#
# Usage: packaging/build-all.sh [name...]
#   no args        build everything (generic + all cloud + all messaging + carddav)
#   name...        build only the named package(s), e.g. `build-all.sh generic dropbox teams`
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

CLOUD_NAMES=(box dropbox flickr gdrive hidrive kdrive koofr mega onedrive pcloud s3 yandex)
MESSAGING_NAMES=(teams telegram signal discord whatsapp facebook googlechat)

build_one() {  # $1 = label, $2 = pkgdir, $3.. = stage command (stage-dir appended as last arg)
  local label="$1" pkgdir="$2"
  shift 2
  echo "############################################################"
  echo "# $label"
  echo "############################################################"
  local stage
  stage="$(mktemp -d)"
  "$@" "$stage"
  bash "$HERE/lib/make-ipk.sh" "$pkgdir" "$stage" "$OUT"
  rm -rf "$stage"
}

want() {  # $1 = name; true if no filter args were given, or $1 is among them
  [ "${#FILTER[@]}" -eq 0 ] && return 0
  local n
  for n in "${FILTER[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

FILTER=("$@")

want generic && build_one generic "$HERE/generic" bash "$HERE/generic/stage.sh"

# core-apps patches (Accounts/Phone/messaging.library/contacts.plugin.messaging/app-services/
# luna-systemui/enyo accounts framework/chatthreader) are no longer built from here -- each now
# has its own self-contained packaging/ tree in its own repo (core-apps, app-services,
# luna-systemui, enyo-1.0, com.palm.messaging.chatthreader), building a whole-directory-replace
# ipk instead of a per-file patch. Build those from their own repos' packaging/build-all.sh.

for name in "${CLOUD_NAMES[@]}"; do
  want "$name" && POSTINST="$HERE/cloud/postinst" PRERM="$HERE/cloud/prerm" build_one "cloud/$name" "$HERE/cloud/$name" bash "$HERE/cloud/stage.sh" "$name"
done

for name in "${MESSAGING_NAMES[@]}"; do
  want "$name" && POSTINST="$HERE/messaging/postinst" PRERM="$HERE/messaging/prerm" build_one "messaging/$name" "$HERE/messaging/$name" bash "$HERE/messaging/stage.sh" "$name"
done

want carddav && build_one carddav "$HERE/carddav" bash "$HERE/carddav/stage.sh"

echo "############################################################"
echo "built $(ls "$OUT"/*.ipk 2>/dev/null | wc -l) package(s) in $OUT"
