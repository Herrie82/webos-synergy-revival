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

1. **`org.webosports.synergy.generic`** first, always — every other package needs it
   (`imlibpurpleservice`, the shared libpurple engine, `_cloudcore`, QuickOffice/Photos/DocViewer
   integration, and the `device-setup/*` device fixes).
2. Any connector package(s) you want (`org.webosports.synergy.dropbox`, `.teams`, `.telegram`, …).
   `org.webosports.cdav` (CardDAV/CalDAV) is fully self-contained and has no dependency on generic.

Connector `control` files deliberately do **not** carry a formal `Depends: org.webosports.synergy.generic`
line — confirmed live that WebOSQuickInstall/Preware refuse the install client-side ("Unable to
install", no trace of the attempt ever reaching the device's own `ApplicationInstallerUtility`/`ipkg`)
when they can't verify a declared dependency against their own subscribed feed, which a side-loaded,
non-feed package like `generic` never is — even though it's actually installed and `ipkg` itself is
completely happy with it. This is advisory-only anyway: neither `ipkg` nor our own postinst/prerm
rely on the `Depends:` field functionally, so dropping it costs nothing except the client tool's own
(broken, in this case) enforcement. Install order above is honor-system, not machine-enforced.

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
- **The shared libpurple 2.14 + ssl-openssl engine** (`messaging/libpurple/lib`) — installed to the
  **real `/usr/lib` + `/usr/lib/purple-2`**, overwriting whatever stock `com.palm.imlibpurple`
  shipped there. Earlier packaging nested this under `com.palm.app.teams`'s own app directory, but
  that was never correct: `libpurple.so.0.14.13` has its plugin-search/sysconfdir/datadir paths
  **compiled in** (autoconf `--libdir`/`--sysconfdir`/`--datadir` at its own build time — confirmed
  via `strings`), so *where the file physically sits* was never what determined its plugin search
  path anyway, and Teams' app has nothing to do with the shared backend. The vendored `.so` here
  has those 3 compiled-in paths **binary-patched** (same technique as the existing
  `device-setup/webkit-webm-mime` fix — each string appears exactly once, patched to a
  shorter real path, NUL-padded) to `/usr/lib/purple-2`, `/etc`, `/usr/share`.

  Because this **overwrites real stock files** (not a private add-on), `generic/postinst` backs up
  whatever's already at each destination to `/media/cryptofs/synergy-stock-backup/...` *once* (idempotent —
  an upgrade doesn't re-clobber the backup with our own previous version) before copying ours in;
  `prerm` restores the stock file if a backup exists, or removes the file cleanly if it doesn't
  (meaning we added it fresh, no stock predecessor) — the same non-destructive pattern already
  used by `device-setup/skype-disable` and `bt-hfg-call-patch`. The replacement files are staged at
  a neutral `/opt/synergy-revival/rootfs-overwrite/...` path in the `.ipk` (not directly at
  `/usr/lib/...`) precisely so postinst gets a chance to back up stock **before** anything is
  overwritten — `data.tar.gz` unpacks before `postinst` runs, so placing the new files directly at
  their final path would clobber stock with no way back.

  Third-party runtime `.so` deps unique to one plugin (`libgcrypt`/`libpng16`/`libwebp`/`libopus`/
  `libstdc++`/...) are a different case: they're incidental link-time dependencies, not "the same
  component being modernized", so overwriting a system-wide file of the same name risks breaking
  unrelated apps that load the stock version. Those go in a **private, non-colliding**
  `/usr/lib/synergy-runtime/` instead (added to `imwrap.sh`'s `LD_PRELOAD`/`LD_LIBRARY_PATH`) —
  connector packages only ever *add* new files there. Connector **prpl plugins themselves**
  (`libteams.so`, `libwhatsmeow.so`, ...) go directly in `/usr/lib/purple-2/` — brand new
  filenames with zero stock-collision risk, no backup needed.

  **Done:** `com.palm.app.teams` is renamed to `org.webosports.app.teams` (matching the
  `org.webosports` vendor namespace used elsewhere) — the app directory, `appinfo.json` `id`, and
  every `customUI.appId`/`readPermissions`/`writePermissions` reference in the account template
  (`com.palm.teams.json`) were updated together, plus every `deploy-*.sh` across all 7 messaging
  connectors and `teams_calling.c`'s two compiled-in `LD_PRELOAD` paths (binary-patched in the
  already-built `libteams-personal(.stripped).so`, same technique as the libpurple.so fix above —
  verified via `readelf -d`/`strings` that each patched string is unique and the source `.c` was
  fixed too so a future rebuild doesn't need re-patching). Cross-checking `readelf -d` against every
  plugin while doing this also caught two real packaging bugs, now fixed: Google Chat's
  `libprotobuf-c.so` was missing its required `.so.1` suffix (dynamic linker matches `NEEDED` by
  exact name — wrong name silently fails plugin load), and Telegram was shipping
  `libgcrypt`/`libpng16`/`libwebp`/`libsharpyuv` left over from the **retired tgl-based**
  `telegram-purple` — the active `tdlib-purple` plugin's only third-party `NEEDED` is
  `libopus.so.0` (now the only thing staged for it).

  **Resolved by cross-checking `StockRootfs` + the attached device**: `readelf -d` showed Telegram
  (tdlib-purple), the combined WhatsApp/Facebook plugin, and Teams all have a hard `NEEDED
  libpalmgstskype.so` **and** an RPATH of exactly `/usr/lib/gstreamer-0.10` baked in — and
  `device-setup/skype-disable` used to move that exact file away. Confirmed on the attached device:
  a backup at `/media/cryptofs/skype-disabled-backup/usr/lib/gstreamer-0.10/libpalmgstskype.so` (byte-identical
  to `StockRootfs`'s copy, `md5 3c73c35d...`) proved skype-disable really had removed it at some
  point, and the live copy back in place (same md5) proved someone had already manually restored it
  by hand to stop it breaking those three connectors. `skype-disable` no longer touches this file
  (fixed in both `device-setup/skype-disable/remove-skype.sh` and this package's `postinst`).

  **Also found and fixed by the same cross-check** (`StockRootfs` vs. the repo vs. the attached
  device):
  - `com.palm.imlibpurple.service` (the on-demand LS2/D-Bus activation file) ships in stock pointed
    straight at the raw `Exec=/usr/bin/imlibpurpletransport`, bypassing `imwrap.sh` entirely — no
    wpe-glibc loader patch, SSL override, PmLog semaphore self-heal, or ALSA preload. The attached
    device had already been hand-patched to `Exec=/var/imwrap.sh ...`, but that fix had never been
    captured anywhere in this repo. Now shipped as a real file
    (`messaging/imlibpurpleservice/imlibpurpleservice/files/dbus-1/system-services/com.palm.imlibpurple.service`)
    and installed the same backup-then-overwrite way as `libpurple.so`.
  - The four calling `.service` files (`com.palm.{whatsapp,teams,signal,telegram}.call.service`) —
    needed so `ls-hubd` knows the bus name exists for *inbound* call routing, even though the
    resident transport registers it in-plugin — existed on the attached device and in three of the
    four connectors' own source trees, but were never staged by packaging at all, and Telegram's
    didn't exist anywhere in the repo (recovered from the attached device and added). Now each
    lands in its own connector's package (new filenames, no stock predecessor, no backup needed).
  - Cross-checked `com.palm.person`'s index count (18 vs. 18) and the three shared `com.palm.im*`
    activity files against `StockRootfs` — byte-identical (aside from a trailing-comma/EOF-newline
    diff) and no gaps.
  - Confirmed `imtransport` is a pure addition (stock has no upstart job by that name — the stock
    transport is on-demand-only), and every db8 kind/permission this repo adds beyond stock
    (`com.palm.imchannel`, `com.palm.imserver`, `com.palm.imretaineddata`, `com.palm.config.libpurple`)
    is additive, never replacing a stock kind.
- **`_cloudcore`** (`/usr/palm/services/_cloudcore`) and **`com.palm.app.cloud-auth`** — every cloud
  connector's `sources.json` loads cloudcore code via a relative `../_cloudcore/...` path, so it
  must land as a sibling of every `/usr/palm/services/com.palm.service.<x>/` dir; the OAuth webview
  app is likewise shared across connectors.
- **QuickOffice / Photos / DocViewer integration** and **`device-setup/*` fixes** — device-wide
  patches/add-ons unrelated to any one connector (gstreamer codecs, chatthreader/contacts patches,
  BT audio routing, the Thai font fallback, the retired-Skype/AOL/Yahoo! cleanup, etc). Each fix's
  own `device-setup/<name>/install*.sh` was the source of truth for what `generic/postinst`
  replicates. `device-setup/legacy-im-disable` (AOL/AIM + Yahoo!, same non-destructive move pattern
  as `skype-disable`) was added directly in `postinst`/`prerm` — no payload files to stage, so it
  isn't in `stage.sh`'s device-setup copy loop, same as `skype-disable` itself.

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
`control` contents), and the generic package's backup-then-overwrite / restore-or-remove logic was
verified in an isolated shell simulation (backup made once, survives a second/upgrade install,
`prerm` restores it or removes cleanly if there was none) — but **nothing has been installed on a
real device** in this pass, no device was attached. Given `generic` now **overwrites real stock
`/usr/lib/libpurple.so*` + `/usr/lib/purple-2/*`**, the on-device install is the important
remaining check: confirm `imtransport` actually starts and loads a plugin against the patched
`libpurple.so.0.14.13` (`status imtransport`, `imstdout.log`), and that `prerm` genuinely restores
the stock files if you ever remove the package.
