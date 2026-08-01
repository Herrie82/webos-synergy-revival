# Packaging

Turns this repo's connectors into real, installable webOS `.ipk` packages: **one per connector**,
plus one shared **`org.webosports.synergy.generic`** package for the infrastructure every
connector depends on. Everything is versioned **0.9.0**.

## Install

**Install via Preware or WebOS Quick Install — NOT `palm-install`.** These packages carry
`postinst`/`prerm` scripts that run as root to lay down files under `/usr/palm/services`,
`/usr/palm/public/accounts`, `/etc/palm/db`, `/usr/share/ls2/roles`, etc. `palm-install` runs as a
non-root user and simply skips those scripts, so the connector would appear installed but not
actually be wired up.

Install order:

1. **`org.webosports.synergy.generic`** first, always — every other package depends on it
   (`imlibpurpleservice`, the shared libpurple engine, `_cloudcore`, QuickOffice/Photos/DocViewer
   integration, and the `device-setup/*` device fixes).
2. Any connector package(s) you want (`org.webosports.synergy.dropbox`, `.teams`, `.telegram`, …).
   `org.webosports.cdav` (CardDAV/CalDAV) is fully self-contained and has no dependency on generic.

## Rebuild

```sh
packaging/build-all.sh                 # everything -> packaging/out/*.ipk
packaging/build-all.sh generic teams   # just these
```

Each package is built by a `stage-*.sh` (copies already-built files — account template, service,
app, prpl plugin — into a local root-relative tree mirroring the final on-device layout) followed
by `packaging/lib/make-ipk.sh` (turns that tree into a real `.ipk`: `ar` of `debian-binary` +
`control.tar.gz` + `data.tar.gz`, injecting `postinst`/`prerm` if the package dir has them). No
compiling happens here — every messaging connector's native `.so` must already be built (see each
connector's own `build-*.sh` / `BUILD-LOG.md`).

Verify a built package:

```sh
ar t packaging/out/org.webosports.synergy.dropbox_0.9.0_all.ipk    # debian-binary control.tar.gz data.tar.gz
tar -xzOf <(ar p packaging/out/…ipk control.tar.gz) ./control       # Package/Version/Depends/Description
tar -tzf <(ar p packaging/out/…ipk data.tar.gz)                     # staged file list
```

## Layout

```
packaging/
  lib/make-ipk.sh, common.sh   the packaging + staging primitives, shared by everything below
  generic/                     stage.sh, control.env, postinst, prerm
  cloud/stage.sh                templated stager: stage.sh <name> <stage-dir>; one control.env per
    <name>/control.env          connector (box, dropbox, flickr, gdrive, hidrive, kdrive, koofr,
                                 mega, onedrive, pcloud, s3, yandex); shared cloud/postinst
  messaging/stage.sh            same pattern for teams, telegram, signal, discord, whatsapp,
    <name>/control.env          facebook, googlechat; shared messaging/postinst
  carddav/                      stage.sh, control.env, postinst, prerm (keeps its own pre-existing
                                 org.webosports.cdav identity, see carddav/package/packageinfo.json)
  build-all.sh                  orchestrator
  out/                          build output (gitignored)
```

## What's in "generic" and why

- **`imlibpurpleservice`** — the transport binary (`/usr/bin/imlibpurpletransport`), its launch
  chain (`imwrap.sh`/`imdaemon.sh`/the `imtransport` upstart job), and the shared messaging db8
  kinds/permissions + LS2 roles. One bridge service handles *every* protocol uniformly — there are
  no per-connector db8 sub-kinds the way a "normal" Synergy service would have.
- **The shared libpurple 2.14 + ssl-openssl backend** (`messaging/libpurple/lib`) — physically
  nested under `com.palm.app.teams`'s own app directory
  (`.../applications/com.palm.app.teams/backend/`) for historical reasons: `imwrap.sh` and every
  messaging connector's own `deploy-*.sh` hardcode that exact path. Relocating it would be a real,
  device-risking behavior change, so it's kept as-is. **Generic owns only the `backend/` subtree**;
  each messaging connector's own package owns `com.palm.app.teams`'s *top-level* setup-app files
  only when it *is* Teams, and every other connector's package just *adds* its plugin `.so` into
  `backend/lib/purple-2/` (new filename each time — no two packages ever own the same file, which
  is exactly how ipkg's shared-directory semantics are meant to be used).
- **`_cloudcore`** (`/usr/palm/services/_cloudcore`) and **`com.palm.app.cloud-auth`** — every cloud
  connector's `sources.json` loads cloudcore code via a relative `../_cloudcore/...` path, so it
  must land as a sibling of every `/usr/palm/services/com.palm.service.<x>/` dir; the OAuth webview
  app is likewise shared across connectors.
- **QuickOffice / Photos / DocViewer integration** and **`device-setup/*` fixes** — device-wide
  patches/add-ons unrelated to any one connector (gstreamer codecs, chatthreader/contacts patches,
  BT audio routing, the Thai font fallback, the retired-Skype cleanup, etc). Each fix's own
  `device-setup/<name>/install*.sh` was the source of truth for what `generic/postinst` replicates.

## Known best-effort / unconfirmed pieces

- **`photos-integration`**: only `LibraryNavigationPanel.css.patch` + the `Utils.js.patch` service
  reroute have a confirmed target path in `photos-integration/README.md`'s own "Applying" section
  (the latter inferred as `com.palm.service.photos`, matching the `photos-src/base/` patch header
  and the `[[photos-aggregator-integration]]` history). `PictureMode.js.patch` and
  `AlbumModeMultiselectControls.js.patch` have ambiguous patch headers with no documented target —
  `generic/postinst` best-effort-applies them against `com.palm.app.photos` and logs (not aborts)
  on failure. If you see the log line, apply them manually per `photos-integration/README.md`.
- **`videoplayer-webm`**: the `libmp-autoplug.so` autoplug shim is intentionally **not** installed
  (it fixes WebM but breaks mp4/H.264 playback) — only the mediastream WebM/MKV mislabel patch runs
  automatically. Apply the shim manually (`MP_SHIM=1`, see `device-setup/videoplayer-webm/README.md`)
  if you need WebM more than mp4 in the stock Video player.
- **Telegram/WhatsApp/Facebook runtime deps** (`libgcrypt`/`libpng16`/`libwebp`/`libsharpyuv` for
  Telegram; `libopusfile`/`libopus`/`libogg` for WhatsApp/Facebook) are pulled from
  `/home/herrie/webos/wpe/staging-glibc-252/lib` at package-*build* time (the same ARM cross-builds
  every existing `deploy-*.sh` already sources from) — rebuilding these packages requires that path
  to exist on the build machine. Once built, the `.ipk` is self-contained; nothing further is
  fetched at install time.
- **CardDAV's Google OAuth `client_secret`** is injected at build time the same way
  `deploy-cdav.sh` already does (env var `CDAV_GOOGLE_CLIENT_SECRET`, or a downloaded
  `client_secret_*.json`) — without it, Google CardDAV/CalDAV setup won't work until you patch
  `GoogleSetup.js` manually.

## Not yet exercised

Every package here has been built and its `.ipk` structure verified (`ar t` / `tar -tzf` /
`control` contents), but **not installed on a real device** in this pass — no device was attached.
Installing via Preware/WebOS Quick Install and confirming `imtransport`/each service comes up is
the remaining verification step.
