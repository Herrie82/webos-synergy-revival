#!/bin/bash
# common.sh — shared staging helpers for packaging/*/stage-*.sh scripts.
# Source this, then call the stage_* functions with $STAGE already set to a stage root dir
# (root-relative paths under $STAGE mirror the final on-device layout, e.g.
# $STAGE/usr/palm/services/..., $STAGE/media/cryptofs/apps/usr/palm/applications/...).
set -euo pipefail

APP_ROOT="media/cryptofs/apps/usr/palm/applications"
ACCOUNTS_ROOT="usr/palm/public/accounts"
SERVICES_ROOT="usr/palm/services"
# Neutral cryptofs staging area for anything destined for a real ROOT-FS path (as opposed to
# APP_ROOT/BACKEND_LIB/BACKEND_PURPLE2 above, which are already on cryptofs). Never write such a
# file directly under $STAGE/<real-path>: ipkg extracts data.tar.gz itself, BEFORE postinst ever
# runs and gets a chance to remount root read-write, so anything landing at a literal root-fs path
# in data.tar.gz fails outright on stock webOS's read-only-by-default root ("Read-only file
# system", confirmed live via Preware/WebOS Quick Install). /media/cryptofs is a separate,
# always-writable fuse mount regardless of root's state; the shared apply_rootfs_overwrite()
# postinst function (duplicated into each package family's postinst) copies everything staged
# here to its real destination, backing up whatever's already there first.
#
# Scoped per-package via $PKG_ID (every stage.sh must `source` its own package's control.env --
# right next to it, e.g. packaging/cloud/$NAME/control.env -- before staging anything) rather than
# one shared path: ipkg's file-ownership tracking is by exact path REGARDLESS of whether the file
# still physically exists after postinst deletes it (confirmed live: installing dropbox after
# generic failed with "wants to install .../rootfs-overwrite/.symlinks, but that file is already
# provided by package com.palm.synergy.generic", even though generic's own postinst had
# already deleted its copy of that same literal path).
#
# Deliberately PKG_ID (com.palm.synergy.teams), not the short connector $NAME (teams): the
# corresponding postinst derives its OWN pkg id from how it was invoked ($0) and must look up
# EXACTLY its own staged subdirectory here, not just "whichever one happens to exist" -- unsafe if
# more than one package's staged data is ever present at once (flagged as a real risk: the old
# NAME-keyed path couldn't be matched against $0's pkg id at all, since they're spelled
# differently, leaving postinst no choice but to blindly glob).
overwrite_rel() {
  : "${PKG_ID:?PKG_ID must be set (source this package control.env) before staging anything through OVERWRITE (stage_root_file/stage_root_dir/stage_account/stage_service)}"
  printf 'media/cryptofs/synergy-revival/rootfs-overwrite/%s' "$PKG_ID"
}
# libpurple.so's own compiled-in plugin search path is /usr/lib/purple-2, and the shared runtime
# deps dir is /usr/lib/synergy-runtime -- but root (/dev/mapper/store-root) is a FIXED, TINY 559MB
# partition, and the connector plugins here are large (WhatsApp/Telegram ~29MB each, Signal
# ~19.5MB): confirmed live that installing all of teams+telegram+signal+whatsapp together filled
# root to 0 bytes free and broke further installs (one mid-install segfault, one corrupted package
# record). /media/cryptofs has 20+GB free on the same device. So the REAL storage for both lives
# on cryptofs, staged here under media/cryptofs/synergy-purple-plugins and
# media/cryptofs/synergy-runtime; generic's postinst + imwrap.sh bind-mount them onto the real
# /usr/lib/purple-2 and /usr/lib/synergy-runtime paths libpurple.so and imwrap.sh's
# LD_LIBRARY_PATH actually expect (cryptofs can't hold symlinks, confirmed elsewhere in this repo,
# so a bind mount -- re-applied every launch since it doesn't survive a reboot -- is the mechanism,
# not a symlink). Every stage_backend_plugin* call below writes to the cryptofs-backed path; only
# the mountpoint dirs themselves are ever created directly under /usr/lib on root.
BACKEND_PURPLE2="media/cryptofs/synergy-purple-plugins"
BACKEND_LIB="media/cryptofs/synergy-runtime"

# stage_root_file <src-file> <dest-abs-path>
# Stages a single file for postinst to copy to the real root-fs <dest-abs-path> (e.g.
# /usr/share/dbus-1/system-services/com.palm.teams.call.service), backing up whatever's already
# there first. See overwrite_rel() above for why this indirection (and its per-$NAME scoping)
# exists at all.
stage_root_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || { echo "!! stage_root_file: $src missing" >&2; return 1; }
  local rel; rel="$(overwrite_rel)"
  mkdir -p "$STAGE/$rel$(dirname "$dst")"
  cp "$src" "$STAGE/$rel$dst"
}

# stage_root_dir <src-dir> <dest-abs-path>
# Same as stage_root_file but for a whole directory (e.g. an account template, a Node service, the
# _cloudcore dir). Symlinks inside src-dir can't be staged through cryptofs at all (rejects
# symlink() outright, confirmed live packaging messaging.library/contacts.plugin.messaging in the
# core-apps repo) -- recorded in a shared manifest instead; apply_rootfs_overwrite() recreates them
# directly at the real destination with a real ln -s.
stage_root_dir() {
  local src="$1" dst="$2"
  [ -d "$src" ] || { echo "!! stage_root_dir: $src missing" >&2; return 1; }
  local rel; rel="$(overwrite_rel)"
  local target="$STAGE/$rel$dst"
  mkdir -p "$target"
  local manifest="$STAGE/$rel/.symlinks"
  mkdir -p "$(dirname "$manifest")"
  touch "$manifest"
  local excludes=()
  local link relpath linktarget
  while IFS= read -r -d '' link; do
    relpath="${link#"$src"/}"
    linktarget="$(readlink "$link")"
    printf '%s\t%s\n' "$dst/$relpath" "$linktarget" >> "$manifest"
    excludes+=(--exclude="$relpath")
  done < <(find "$src" -type l -print0)
  tar -C "$src" "${excludes[@]}" -cf - . \
    | tar -C "$target" -xf -
}

# stage_account <src-dir> <template-id>
# Copies an account-template directory (json + images) to /usr/palm/public/accounts/<template-id>/
stage_account() {
  local src="$1" id="$2"
  stage_root_dir "$src" "/$ACCOUNTS_ROOT/$id"
}

# stage_service <src-dir> <service-id>
# Copies a Node service directory to /usr/palm/services/<service-id>/
stage_service() {
  local src="$1" id="$2"
  stage_root_dir "$src" "/$SERVICES_ROOT/$id"
}

# stage_app <src-dir> <app-id>
# Copies an app bundle directory to /media/cryptofs/apps/usr/palm/applications/<app-id>/ - routed
# through stage_root_dir (the overwrite_rel() OV mechanism), NOT written directly under
# $STAGE/$APP_ROOT. Writing directly there used to mean staging a tar entry that ALREADY starts
# with "media/cryptofs/apps/...", which Preware/WebOS Quick Install's offline-root ipkg invocation
# (`ipkg -o /media/cryptofs/apps install <ipk>`) then extracts relative to ITS OWN
# /media/cryptofs/apps root, prepending that prefix a second time
# (confirmed live: landed at /media/cryptofs/apps/media/cryptofs/apps/usr/palm/applications/<id>,
# where App Manager never looks - "Could not get app path: Invalid appId specified"). Routing
# through the OV mechanism sidesteps this entirely: postinst reads the real destination out of
# dest.txt as a literal string and cp's there explicitly, so it lands correctly regardless of
# which root ipkg extracted the archive relative to. stage_account/stage_service (below) never had
# this bug for exactly this reason - this just brings stage_app in line with them.
stage_app() {
  local src="$1" id="$2"
  stage_root_dir "$src" "/$APP_ROOT/$id"
}

# stage_app_files <src-dir> <app-id> <file>...
# Copies only the named files (relative to src-dir, preserving subdirs) into the app bundle —
# (historical -- no longer used now that the shared engine lives at /usr/lib, not nested in any app dir).
stage_app_files() {
  local src="$1" id="$2"; shift 2
  local dest="$STAGE/$APP_ROOT/$id"
  local f
  for f in "$@"; do
    [ -f "$src/$f" ] || { echo "!! stage_app_files: $src/$f missing (skip)" >&2; continue; }
    mkdir -p "$dest/$(dirname "$f")"
    cp "$src/$f" "$dest/$f"
  done
}

# Runtime .so deps: each connector's own stage_backend_plugin* call only ever lists a runtime lib
# that's UNIQUE to that one connector (verified with `readelf -d` against every plugin .so + the
# transport binary itself -- see BUILD-LOG.md / this repo's commit history for the full table).
# Anything needed by 2+ packages (libopus/libogg/libtidy -- all three actually NEEDED by the
# transport binary itself, so truly universal; libopusfile -- shared by WhatsApp+Facebook) is
# staged ONCE by generic instead, since every connector already hard-depends on generic being
# installed (PKG_DEPENDS) -- no connector needs to carry a defensive copy of something generic is
# guaranteed to provide. This avoids ipkg's file-ownership conflict ("wants to install file X but
# that file is already provided by package Y", confirmed live installing telegram then whatsapp
# when both shipped their own libopus.so.0 copy) without needing a payload/copy-on-postinst
# workaround -- with the shared libs owned solely by generic, no two packages ever claim the same
# filename in the first place.
# Both stage_backend_plugin* below route through stage_root_file (the overwrite_rel() OV
# mechanism) rather than writing directly under $STAGE/$BACKEND_PURPLE2 or $STAGE/$BACKEND_LIB -
# same reason as stage_app above: those paths already start with "media/cryptofs/...", which
# Preware/WebOS Quick Install's offline-root ipkg invocation would otherwise double-prefix.
stage_backend_plugin() {
  local so="$1"; shift
  [ -f "$so" ] || { echo "!! stage_backend_plugin: $so missing" >&2; return 1; }
  stage_root_file "$so" "/$BACKEND_PURPLE2/$(basename "$so")"
  local lib
  for lib in "$@"; do
    [ -f "$lib" ] || { echo "!! stage_backend_plugin: runtime dep $lib missing (skip)" >&2; continue; }
    stage_root_file "$lib" "/$BACKEND_LIB/$(basename "$lib")"
  done
}

# stage_backend_plugin_as <so-file> <dest-name> [runtime-lib]...
# Same as stage_backend_plugin but renames the .so on the way in (e.g. libtelegram-tdlib.stripped.so
# -> libtelegram-tdlib.so, matching what the transport's g_module lookup expects).
stage_backend_plugin_as() {
  local so="$1" name="$2"; shift 2
  [ -f "$so" ] || { echo "!! stage_backend_plugin_as: $so missing" >&2; return 1; }
  stage_root_file "$so" "/$BACKEND_PURPLE2/$name"
  local lib
  for lib in "$@"; do
    [ -f "$lib" ] || { echo "!! stage_backend_plugin_as: runtime dep $lib missing (skip)" >&2; continue; }
    stage_root_file "$lib" "/$BACKEND_LIB/$(basename "$lib")"
  done
}

# bump_version <file>
# Rewrites a top-level "version": "x.y.z" field to 0.9.0 in a staged copy of a json file (does
# not touch the source repo file).
bump_version() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -i 's/"version"[[:space:]]*:[[:space:]]*"[^"]*"/"version": "0.9.0"/' "$f"
}
