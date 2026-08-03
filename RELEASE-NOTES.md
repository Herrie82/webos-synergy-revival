# Synergy Revival — Release Notes (2026-08)

This covers two families of packages:

- **Part 1** — 11 core webOS app/framework components, each now a self-contained
  whole-directory-replace `.ipk` built from its own repo (no more ad-hoc `novacom put` or
  surgical per-file patching from `webos-synergy-revival`).
- **Part 2** — the connector packages built from `webos-synergy-revival` itself (Synergy cloud
  and messaging account providers), version `0.9.0`.

All packages install with `ipkg install` (Preware / WebOS Quick Install) — **not**
`palm-install`, which runs as non-root and skips `postinst`/`prerm` entirely, so nothing actually
gets applied. Each Part 1 package is a full replacement of the stock directory (backed up once,
restorable via `ipkg remove`), not a diff — safe on a virgin device or one already carrying older
patches.

## Installation

**Order matters between the two phases below — not so much within them.**

### 1. Core app/framework packages (Part 1) — any order, but install the whole set

`ipkg install <name>_<version>_all.ipk` for as many of the 11 packages below as you want. None of
them touch each other's files, so they install fine in any order and any subset — but several
*features* cross-reference each other: the SYNERGY ACCOUNTS grouping needs both
`com.palm.app.accounts` **and** `enyo-accounts`; the keep-data-on-remove flow needs
`enyo-accounts` + `com.palm.service.accounts` + `com.palm.app.accounts` together; the full
messaging feature set wants `com.palm.app.messaging` + `messaging.library` +
`contacts.plugin.messaging` + `com.palm.messaging.chatthreader` + `com.palm.service.contacts.linker`
all present. Install the whole set unless you have a specific reason not to.

### 2. Connector packages (Part 2) — `generic` first, then any connectors, any order

`org.webosports.synergy.generic` is a **hard functional dependency** for every messaging and
cloud connector (it ships the actual `imlibpurpleservice` binary, the libpurple backend, and
`_cloudcore`) — but that isn't enforced by ipkg itself (no `Depends:` field is set). Installing a
connector before `generic` won't fail the install, it'll just sit there non-functional until
`generic` is in too. **Install `generic` before any messaging or cloud connector.** After that,
install any subset of the 7 messaging and 12 cloud connectors, in any order — they don't share
files either.

### 3. Restart once, then set up accounts

Once everything above is installed, restart the UI (`stop LunaSysMgr; start LunaSysMgr`, or just
reboot) — this is the one point where every whole-directory replacement actually takes effect.
Then add or re-enable each Synergy account under **Settings → Accounts**.

### Upgrading an existing install

Account data (db8 records: accounts, messages, contacts) isn't touched by any of this — only
application/framework/service *code* is replaced — so existing Synergy accounts and message
history survive an upgrade untouched.

## Part 1 — Core app/framework packages

| Package | Version | Repo | Stock baseline |
|---|---|---|---|
| `com.palm.app.accounts` | 3.1.1 | core-apps | 3.0-40 |
| `com.palm.app.phone` | 3.1.1 | core-apps | 3.0-84.2 |
| `com.palm.app.messaging` | 3.1.0 | core-apps | 3.0-66.2 |
| `messaging.library` | 1.4.0 | core-apps | 1.0-1.3 |
| `contacts.plugin.messaging` | 12.2.0 | core-apps | 1.0-12.1 |
| `com.palm.service.accounts` | 1.1.0 | app-services | 1.0-78 |
| `com.palm.service.contacts.linker` | 1.1.0 | app-services | 1.0-77 |
| `luna-systemui` | 3.1.1 | luna-systemui | 3.0-300.56 |
| `enyo-accounts` | 1.1.1 | enyo-1.0 | 1.0-7 |
| `com.palm.messaging.chatthreader` | 1.1.0 | com.palm.messaging.chatthreader | 1.0-52 |

---

### `com.palm.app.messaging` — 3.1.0

The Messaging app itself — by far the largest single component (89 commits). Brings back the
message-level features every dead Synergy IM connector needs to feel like a first-party
experience.

- **Reactions** — swipe/tap to react, emoji picker filtered per-network capability, inline
  reaction badges on bubbles (not a separate "reacted with X" line), tap your own badge to
  remove it. Group/channel messages react to the *channel*, not the sender.
- **Replies** — native reply-compose with quoted-field selection; incoming replies render as an
  inline quote card instead of raw `> …` text.
- **Receipts** — delivery/read tick marks on outgoing messages, styled after the stock
  luna-systemui checkmark; flyweight-render fix so ticks don't collide with reaction badges.
- **Voice messages** — record button (native `MediaCaptureV3`) with staged-chip playback preview;
  inline voice-note player plays in the bubble (no external app); AAC `.m4a`/`.aac` voice notes
  tagged correctly so they load.
- **Attachments** — pick video and documents to send (was image-only); incoming documents render
  as typed icon chips that open in-app; tappable media chips open a real player; WhatsApp video
  gets a poster-thumbnail preview; inline WebM/VP9 plays by mislabeling the `<source>` mime,
  mp4 taps route to the stock fullscreen player.
- **Failed-message resend** — "Send again" restored for both `failed` and IM `permanent-fail`;
  persistent dashboard notification for unsent messages with tap-to-resend, survives restarts.
- **Calling UI** — voice-call button shown only for phone-capable services; video calling via
  Atlas WebRTC (Jitsi room opened from a 1:1 conversation); header call-icon set refreshes when
  the transport dropdown changes.
- **Servers tab (M2)** — new tab for MUC/guild-style networks: server → channel drill-down,
  channel thread created on tap, per-service connector logos, unread/status indicators.
- **Groups/channels** — sender name shown on incoming group/channel messages, tap a sender to
  open a 1:1 with them, service logo shown for group chats in the thread list, duplicate-chatthread
  fix (find-or-reuse on channel open), WhatsApp thread unify.
- **Rendering/polish** — Unicode emoji as inline EmojiOne images (stripped from notification
  titles/System Bar banners), full-URL linkify as one anchor + picture-caption layout, notification
  HTML-entity fix, Contact Detail dialog sized to content, inline-image row-height jitter fix,
  self-status Offline-while-online fix during buddy sync, stop doubling line breaks in multi-line
  WhatsApp messages, stop notification pings for back-filled history.
- **Stability** — db8 watch leak fixed in thread/buddy/server-room lists, audio players
  `preload="none"` (media-pipeline fd-leak/crash), mic capture device unloaded after recording
  (mediaserver fd leak), "recipient is offline" nag suppressed for login-code auth chats.
- **Housekeeping (this session)** — packaged as a whole-app `.ipk` for the first time (previously
  deployed only via manual `novacom put`); confirmed byte-for-byte match with the live device via
  full md5 manifest before packaging.

### `com.palm.app.accounts` — 3.1.1

- Synergy accounts list grouped into a nested **SYNERGY ACCOUNTS** box, separate from stock
  account types.
- **Delete Account Data** page: removing an account with "keep data" unchecked offers a follow-up
  screen to wipe retained on-device data (messages/contacts/media) after the fact.
- *(this session)* Restored the `resources/` locale directory (de/it/es/es_es/fr_ca/en_ca/en/fr),
  which had been entirely absent from this fork versus stock — non-English UI would otherwise
  regress.

### `com.palm.app.phone` — 3.1.1

- Synergy calling accounts (Add/Modify) now managed from the Accounts app instead of Phone's own
  preferences pane.
- Service-agnostic IM calling UI: "For Calls Use" pickers built dynamically from any
  PHONE-capable account (Signal/Telegram/WhatsApp/…), not hardcoded to Skype/WhatsApp.
- Calls offered via *any* enabled PHONE-capable account, not just a hardcoded WhatsApp special
  case; VoIP calls routed to the chosen IM transport with E.164-cleaned addresses for the plugins.
- Skype UI cleanup: dead/broken Skype hooks removed, `skypeBuddyCache` guarded (was absent after
  Skype removal, crashed `create()` on launch-for-call — this is what "Unable to connect" on
  outgoing WhatsApp calls turned out to be).
- Call-card polish: network label stacked below the number and centered, address ellipsized so
  the label never falls off; incoming video `<video>` tag retries once a real stream URI lands.
- *(this session)* Restored the missing `en_au` (Australian English) locale
  (`resources/en/au/appinfo.json`, `resources/en_au.json`) — a true gap versus stock, distinct
  from this fork's own added `zh`/`zh_cn` locale, which was kept.

### `messaging.library` — 1.4.0

- Vendored the shared framework from stock webOS 3.0.5 as the source of truth (was previously
  unpackaged).
- WhatsApp addresses canonicalized to **E.164** (`+phone`) everywhere, fixing threads that showed
  a bare number instead of the linked contact's name (two normalizers — contacts vs. messaging —
  previously disagreed on whether to keep the `+`).
- Added `appinfo.json` so the framework can be packaged as an ipk at all.

### `contacts.plugin.messaging` — 12.2.0

- Imported from stock webOS 3.0.5 as the source of truth.
- Skips redundant re-association for contacts already linked to an IM buddy (the "BIG HACK" guard
  fix) — was needlessly re-running the linker on every buddy-list refresh.

### `com.palm.service.accounts` — 1.1.0

- `keepData`/`alias`/`templateId` threaded through the delete flow to each capability's
  `onDelete` handler, backing the Accounts app's "keep data on this device" checkbox.

### `com.palm.service.contacts.linker` — 1.1.0

- The four similarity-ranker reads (`mapReduce`) now run **concurrently** instead of serially —
  cuts the ~6–18 minute post-import linker pass, since the original was IPC-read-bound.
- *(this session)* Packaging preserves `filecache_types/{contactphoto,contactvcard}` (live
  contact-photo/vCard cache) across install/upgrade/removal instead of deleting it in the
  wholesale directory replace.

### `luna-systemui` — 3.1.1

- FilePicker album grid sorts **newest-first**.
- *(this session)* Restored the missing `resources/` locale directory (de/it/es/es_es/fr_ca/
  en_ca/en/fr, including per-locale FilePicker `appinfo.json`) — absent entirely from this fork,
  excluded by a `.gitignore` line apparently meant for build-time-generated resources.

### `enyo-accounts` — 1.1.1 (enyo-1.0 framework)

- Add-Account and the existing-accounts list grouped by category (backs the Accounts app's
  SYNERGY ACCOUNTS box).
- "Keep this account's data on this device" opt-out checkbox in the Remove Account confirmation
  dialog; wired through to the account's `onDelete` (default unchecked = historical wipe-on-remove
  behavior).
- Contact Detail popup: adaptive height, taller for the extra Edit row, "Edit Contact" moved into
  the dialog chrome, IM rows labeled by service instead of generic "IM".
- *(this session)* Restored the missing `resources/` locale directory (same 8 locales as above)
  and a UTF-8 BOM in `depends.js` that had been dropped during a prior edit.

### `com.palm.messaging.chatthreader` — 1.1.0

- MUC/channel messages routed to per-channel chatthreads via `imserver`/`imchannel` (was one flat
  thread per protocol).
- Channel display name self-heals from the transport's `channelDisplayName` on later messages
  instead of getting stuck on a stale value or a raw JID.
- Self-heal loop-breaker so a single poison message can't spin the thread-fixer forever (parks
  after 5 unthreaded attempts).
- Adopts a pre-existing stale thread instead of forking a duplicate when a contact link resolves
  late.
- WhatsApp raw-JID guard + person-link fallback (`_isRawId`, `findPersonViaBuddy`) merged in from
  ad hoc device patches — this is what fixed group chats showing a raw JID instead of the group
  name.
- 8 bugs fixed in the original stock service (2 critical) plus real-time throughput work on the
  verified message-routing base.

---

## Part 2 — webos-synergy-revival connector packages (0.9.0)

Reviving defunct Synergy account connectors on the HP TouchPad. Full connector-by-connector
capability matrices (IM/replies/reactions/receipts/calling for messaging; auth/doc/photo for
cloud) are in [`README.md`](README.md) and [`messaging/README.md`](messaging/README.md) — this is
a packaging-level summary.

- **`org.webosports.synergy.generic`** — shared runtime every other package depends on:
  `imlibpurpleservice` + libpurple 2.14 + ssl-openssl backend, `_cloudcore` (shared OAuth/ACL code
  for every cloud connector), the `com.palm.app.cloud-auth` OAuth webview, QuickOffice/Photos/
  DocViewer integration, and every `device-setup/*` fix folded into one `postinst` (Bluetooth
  A2DP/HFP call-audio fixes, Skype/legacy-AIM-Yahoo disable, gstreamer Opus/VP8/VP9/Matroska
  codec backports, font fixes, db8 maintenance). Replaces/conflicts with any hand-installed
  standalone `imlibpurpleservice` package. Runtime plugin/backend libs bind-mount from
  `/media/cryptofs` (root's 559 MB partition can't hold them).
- **Messaging connectors (7)** — `teams`, `telegram`, `discord`, `whatsapp`, `facebook` (E2EE)
  are verified end-to-end on device (IM, reactions, replies, receipts where supported); WhatsApp
  and Telegram additionally have working two-way voice calls; `signal` works with the transport
  crash-loop contained via try/catch; `googlechat` is built but largely untested. Each package
  ships only its own plugin `.so` (+ any runtime libs unique to it, e.g. Telegram's libgcrypt/
  libpng16/libwebp) — shared libs (opus/ogg/opusfile/protobuf-c/libstdc++) moved to `generic` so
  no two packages fight over the same tracked file.
- **Cloud connectors (12)** — `dropbox`, `kdrive`, `box`, `onedrive`, `gdrive`, `pcloud`,
  `yandex`, `mega`, `koofr`, `hidrive` verified end-to-end on device (sign-in, browse, upload/
  download byte-exact, QuickOffice open+save-back, Photos source where supported); `s3` and
  `flickr` are code-complete but not yet exercised on a live account.
- **`org.webosports.cdav`** (CardDAV/CalDAV, own pre-existing namespace) — reviving
  `org.webosports.service.cdav` on stock 3.0.5; de-risked (Node 0.4.12 + `https` confirmed
  working), needs a custom setup app.

### Packaging infrastructure changes (this session)

- Shared runtime libraries (libopus/libogg/libopusfile, libstdc++, libnsl, libtidy) consolidated
  into `generic` only; per-connector packages no longer duplicate them (was causing ipkg
  file-ownership conflicts on install).
- Fixed a live-mmap corruption bug: `postinst` now stops `imtransport` *before* touching any
  shared runtime file, not after.
- Root-partition exhaustion fixed by bind-mounting `/usr/lib/purple-2` and
  `/usr/lib/synergy-runtime` from `/media/cryptofs` (re-established on every launch and at
  install time).

---

## Post-release fix: install failure on read-only root

Shortly after the initial release, installing any Part 1 package via Preware or WebOS Quick
Install failed with `no /opt/core-apps-overwrite/*/dest.txt found, nothing to install` (or the
equivalent path for whichever repo's package it was). Root cause: stock webOS boots root
**read-only**, and `ipkg` extracts `data.tar.gz` itself *before* `postinst` ever runs and gets a
chance to remount root read-write — every Part 1 package staged its payload under `/opt/...`,
which is on the root filesystem, so that extraction silently failed outright.

Fixed by staging under `/media/cryptofs/...` instead — a separate FUSE mount that's always
writable regardless of root's state, matching the convention used by every published webOS
Internals AUSMT patch. `postinst` still remounts root read-write itself, but only needs to for the
final copy from cryptofs to the real destination, not for ipkg's own extraction step.

That surfaced one more bug: `/media/cryptofs` (FUSE) rejects `symlink()` outright, and
`messaging.library`/`contacts.plugin.messaging` both carry a `version/1.0 -> ../submission/x.y`
symlink as part of their stock layout. Packaging now records symlinks separately and excludes them
from the cryptofs-staged payload; `postinst` recreates them with a real `ln -s` at the final
(root-fs) destination after copying the rest of the payload there.

Both fixes are in the shared `packaging/lib/common.sh`/`postinst` across all five Part 1 repos;
version numbers were not bumped for this fix since it's packaging-only (no source changes).

## Audit notes

Every Part 1 component was diffed recursively against a stock webOS 3.0.5 rootfs snapshot before
packaging. Nearly all resulting differences were confirmed harmless (LG's Apache-2.0 open-source
license headers, trailing-newline normalization, re-encoded PNGs) or deliberate upstream removals
(e.g. `FirstLaunch.js`, matched by its own `depends.js` edit) — not accidental drift. Four real
gaps were found and fixed, all locale-related (noted per-package above with *(this session)*
tags): missing `resources/` in `com.palm.app.accounts`, `enyo-accounts`, and `luna-systemui`, and
a missing `en_au` locale in `com.palm.app.phone`.
