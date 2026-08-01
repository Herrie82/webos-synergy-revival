#!/bin/bash
# common.sh — shared staging helpers for packaging/*/stage-*.sh scripts.
# Source this, then call the stage_* functions with $STAGE already set to a stage root dir
# (root-relative paths under $STAGE mirror the final on-device layout, e.g.
# $STAGE/usr/palm/services/..., $STAGE/media/cryptofs/apps/usr/palm/applications/...).
set -euo pipefail

APP_ROOT="media/cryptofs/apps/usr/palm/applications"
ACCOUNTS_ROOT="usr/palm/public/accounts"
SERVICES_ROOT="usr/palm/services"
BACKEND_APP_ID="com.palm.app.teams"
BACKEND_PURPLE2="$APP_ROOT/$BACKEND_APP_ID/backend/lib/purple-2"
BACKEND_LIB="$APP_ROOT/$BACKEND_APP_ID/backend/lib"

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
# for connectors that share com.palm.app.teams's app dir and must not clobber its backend/ tree.
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
# Drops a libpurple prpl plugin (renamed to $2-basename or as-is) into the shared backend's
# purple-2 plugin dir, and any extra runtime .so deps into backend/lib/ alongside it. This
# directory belongs to the generic package (imlibpurpleservice + libpurple engine); connector
# packages only ADD files here, never touch what's already there.
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
