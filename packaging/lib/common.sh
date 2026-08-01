#!/bin/bash
# common.sh — shared staging helpers for packaging/*/stage-*.sh scripts.
# Source this, then call the stage_* functions with $STAGE already set to a stage root dir
# (root-relative paths under $STAGE mirror the final on-device layout, e.g.
# $STAGE/usr/palm/services/..., $STAGE/media/cryptofs/apps/usr/palm/applications/...).
set -euo pipefail

APP_ROOT="media/cryptofs/apps/usr/palm/applications"
ACCOUNTS_ROOT="usr/palm/public/accounts"
SERVICES_ROOT="usr/palm/services"
# libpurple.so's own compiled-in plugin search path (patched, see generic/stage.sh) is the real
# rootfs /usr/lib/purple-2 -- it never belonged under com.palm.app.teams (renamed org.webosports.app.teams; that app dir had nothing
# to do with the shared backend; it was just where an earlier pass happened to stash it).
BACKEND_PURPLE2="usr/lib/purple-2"
# Private, non-stock-colliding location for third-party runtime .so deps unique to specific prpls
# (libgcrypt/libpng16/libwebp/libopus/libstdc++/...). Deliberately NOT /usr/lib: overwriting a
# system-wide lib of the same name with our specific cross-built version could break unrelated
# apps that also load it. libpurple.so + purple-2/ itself is the one exception that DOES overwrite
# the real /usr/lib (see generic/stage.sh + postinst's backup-before-overwrite).
BACKEND_LIB="usr/lib/synergy-runtime"

# stage_account <src-dir> <template-id>
# Copies an account-template directory (json + images) to /usr/palm/public/accounts/<template-id>/
stage_account() {
  local src="$1" id="$2"
  [ -d "$src" ] || { echo "!! stage_account: $src missing" >&2; return 1; }
  mkdir -p "$STAGE/$ACCOUNTS_ROOT/$id"
  cp -r "$src/." "$STAGE/$ACCOUNTS_ROOT/$id/"
}

# stage_service <src-dir> <service-id>
# Copies a Node service directory to /usr/palm/services/<service-id>/
stage_service() {
  local src="$1" id="$2"
  [ -d "$src" ] || { echo "!! stage_service: $src missing" >&2; return 1; }
  mkdir -p "$STAGE/$SERVICES_ROOT/$id"
  cp -r "$src/." "$STAGE/$SERVICES_ROOT/$id/"
}

# stage_app <src-dir> <app-id>
# Copies an app bundle directory to /media/cryptofs/apps/usr/palm/applications/<app-id>/
stage_app() {
  local src="$1" id="$2"
  [ -d "$src" ] || { echo "!! stage_app: $src missing" >&2; return 1; }
  mkdir -p "$STAGE/$APP_ROOT/$id"
  cp -r "$src/." "$STAGE/$APP_ROOT/$id/"
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

# stage_backend_plugin <so-file> [runtime-lib]...
# Drops a libpurple prpl plugin into the real /usr/lib/purple-2 (libpurple's own compiled-in
# plugin search path), and any extra runtime .so deps into the private synergy-runtime dir
# alongside it. Connector packages only ADD new filenames here (their plugin has never existed on
# stock) — never touch/overwrite what's already there; that's generic's job for libpurple.so itself.
stage_backend_plugin() {
  local so="$1"; shift
  [ -f "$so" ] || { echo "!! stage_backend_plugin: $so missing" >&2; return 1; }
  mkdir -p "$STAGE/$BACKEND_PURPLE2"
  cp "$so" "$STAGE/$BACKEND_PURPLE2/"
  local lib
  for lib in "$@"; do
    [ -f "$lib" ] || { echo "!! stage_backend_plugin: runtime dep $lib missing (skip)" >&2; continue; }
    mkdir -p "$STAGE/$BACKEND_LIB"
    cp "$lib" "$STAGE/$BACKEND_LIB/"
  done
}

# stage_backend_plugin_as <so-file> <dest-name> [runtime-lib]...
# Same as stage_backend_plugin but renames the .so on the way in (e.g. libtelegram-tdlib.stripped.so
# -> libtelegram-tdlib.so, matching what the transport's g_module lookup expects).
stage_backend_plugin_as() {
  local so="$1" name="$2"; shift 2
  [ -f "$so" ] || { echo "!! stage_backend_plugin_as: $so missing" >&2; return 1; }
  mkdir -p "$STAGE/$BACKEND_PURPLE2"
  cp "$so" "$STAGE/$BACKEND_PURPLE2/$name"
  local lib
  for lib in "$@"; do
    [ -f "$lib" ] || { echo "!! stage_backend_plugin_as: runtime dep $lib missing (skip)" >&2; continue; }
    mkdir -p "$STAGE/$BACKEND_LIB"
    cp "$lib" "$STAGE/$BACKEND_LIB/"
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
