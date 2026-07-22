# webOS Synergy Revival

Reviving the defunct **Synergy** account connectors on the HP TouchPad (webOS 3.0.5,
`nova-cust-image-topaz`). The stock connectors died with their backends (old APIs,
2009-era TLS, closed helper apps). This repo modernizes two families of them:

- **Cloud / file connectors** — OAuth2/PKCE (or token / SigV4 / E2E-crypto) account sign-in,
  modern-TLS transport, and real file/photo I/O, decoupled from the dead QuickOffice engine.
  They light up **Settings → Accounts**, the **QuickOffice** file browser, and the stock
  **Photos** app.
- **Messaging / IM connectors** — modern chat networks brought back to the stock **Messaging**
  app (and, where built, the **Phone** app for calls) via `libpurple` protocol plugins bridged
  into webOS by `imlibpurpleservice`. Details live in [`messaging/README.md`](messaging/README.md).

## Cloud / file connectors

Capabilities: **Doc** = DOCUMENTS (QuickOffice file browse/open/save + files app);
**Photo** = PHOTO.UPLOAD (appears as a source in the stock Photos app).
✅ works · 🟡 partial/off-device only · ❌ n/a for this service.

| Connector | Auth | Doc | Photo | State |
|---|---|:--:|:--:|---|
| **Dropbox** | OAuth2 + PKCE (public, no secret) | ✅ | ✅ | ✅ **verified end-to-end on device** — reference implementation |
| **kDrive** (Infomaniak) | personal API token (Bearer) | ✅ | ✅ | ✅ **deployed + verified on device** — sign-in, browse, QuickOffice, upload/save-back, photo source all exercised |
| **Box** | OAuth2 + PKCE (secret optional) | ✅ | ✅ | ✅ **verified on device** — sign-in, browse, upload/download, QuickOffice, photo source |
| **OneDrive** | OAuth2 + PKCE (no secret, MS Graph) | ✅ | ✅ | ✅ **verified on device** — sign-in, browse, upload/download, Camera Roll photos |
| **Google Drive** | OAuth2 + PKCE **+ client_secret** | ✅ | ❌ | ✅ **verified on device** (personal/≤100-user) — sign-in, browse, upload/download; Google Photos not reachable headlessly. [recon](recon/google-drive.md) |
| **pCloud** | OAuth2 + secret (no PKCE); US/EU host | ✅ | ✅ | ✅ **verified on device**; [recon](recon/pcloud.md) |
| **Yandex Disk** | OAuth2 + PKCE (+ secret), `Authorization: OAuth` | ✅ | ✅ | ✅ **verified on device**; [recon](recon/yandex.md) |
| **MEGA** | email + password (no OAuth) + **E2E crypto** | ✅ | ✅ | ✅ **verified on device** — email+password sign-in, browse, download and upload work; pure-JS AES/RSA/PBKDF2 crypto with device-specific fixes (key-gen, PBKDF2, AES-CTR, meta-MAC); [details](cloud/mega/README.md) |
| **Koofr** | OAuth2 (secret + PKCE, scope `public`) | ✅ | ✅ | ✅ **verified on device**; [details](cloud/koofr/README.md) |
| **HiDrive** (STRATO) | OAuth2 + secret (refresh-on-401) | ✅ | ✅ | ✅ **verified on device**; [details](cloud/hidrive/README.md) |
| **S3-compatible** (AWS S3 / IDrive e2 / B2 / Wasabi / MinIO / Storj) | **AWS SigV4** (user-supplied keys; nothing to register) | ✅ | ✅ | 🟡 code-complete — SigV4 vs AWS official test vectors + full mock-server flow validated; on-device account pending; [details](cloud/s3/README.md) |
| **Flickr** | **OAuth 1.0a** (HMAC-SHA1, signed in node) | ❌ | ✅ | 🟡 code-complete (signer verified vs OAuth 1.0a test vector) — untested pending a Flickr API key+secret; [recon](recon/flickr.md) |
| Facebook / LinkedIn | — | ❌ | ❌ | ❌ dead as photo sources (private APIs, perms revoked); recon only |
| Instagram | — | ❌ | ❌ | ❌ dead (Basic Display API shut down 2024-12; successors need Business acct + secret + App Review); [recon](recon/instagram.md) |
| Snapfish | — | ❌ | ❌ | ⚠️ marginal (private OAuth gateway); recon only |

Most connectors have been **run on real hardware** — Dropbox, kDrive, MEGA, Box, OneDrive,
Google Drive, pCloud, Yandex Disk, Koofr and HiDrive: an account is created and survives reboots,
files browse/upload/download byte-exact, QuickOffice opens and saves them back, and (where
supported) the cloud folder appears as an album in the Photos app. Only **S3** (needs an on-device
account) and **Flickr** (needs an API key+secret) remain unexercised on device; both reuse the
same verified plumbing.

### QuickOffice + Photos integration (shared, not connectors)

| Piece | What it does | State |
|---|---|---|
| **QuickOffice reroute** | Reroutes QuickOffice's dead MX proxy onto any DOCUMENTS account (list + open + **save-back**); account-derived, zero code per new connector; fits both the Office and PDF apps | ✅ **verified on device** across Dropbox/Box/OneDrive/Drive/pCloud/Yandex/kDrive/Koofr/HiDrive (identical path per connector) |
| **Photos integration** | Patches to stock `com.palm.service.photos` so any PHOTO.UPLOAD account becomes a Photos source (templateId→service routing + per-service Library icons) | ✅ dynamic source recognition + system curl; routes Dropbox/Box/OneDrive/pCloud/Flickr/kDrive/Yandex/MEGA/Koofr/HiDrive |
| **Doc viewer** | Atlas-hosted viewer PoC for file types the frozen native QuickOffice engine can't (PDF/docx/xlsx via JS libs; text/images zero-dep, view-only) | 🧪 PoC on device — text/image renderers work end-to-end; PDF.js/mammoth/SheetJS **not committed** (drop in per `docviewer/.../lib/README.md`) |

## Messaging / IM connectors

Synergy **IM** account providers, each bridging a `libpurple` protocol plugin into the stock
Messaging (and, for calls, Phone) app. Capabilities: **IM** = text · **Images / Audio / Video**
= attachments · **Voice / Video call** = calls. ✅ works · 🟡 partial / built-not-yet-verified ·
❔ not documented as verified on webOS · ❌ none.

| Connector | Plugin | Auth | IM | Images | Audio | Video | Voice call | Video call |
|---|---|---|:--:|:--:|:--:|:--:|:--:|:--:|
| **Teams** | `purple-teams` | OAuth device-code → refresh_token | ✅ | ❔ | ❔ | ❔ | ❌ | ❌ |
| **Telegram** | `tdlib-purple` (TDLib + libtgvoip) | phone + login code | ✅ | ❔ | ❔ | ❔ | 🟡 | ❌ |
| **Signal** | `purple-signal` / presage (JVM + Rust libsignal) | phone register / device link | ✅ | ❔ | ❔ | ❔ | 🟡 | ❌ |
| **Discord** | `purple-discord` (+ libqrencode) | email+pw / QR / paste-token | ✅ | ❔ | ❔ | ❔ | 🟡 | ❌ |
| **WhatsApp** | `purple-gowhatsapp` (whatsmeow, Go) + `wacallm` | phone + QR / pairing code | ✅ | 🟡 | 🟡 | 🟡 | 🟡 | ❌ |
| **Google Chat** | `purple-googlechat` (+ protobuf-c) | 5 pasted browser cookies | ✅ | ❔ | ❔ | ❔ | ❌ | ❌ |
| **Facebook (E2EE)** | `purple-gometa` (mautrix-meta, Go) | `c_user`/`xs`/`datr` cookies | ✅ | ❔ | ❔ | ❔ | ❌ | ❌ |

Notes:
- **IM ✅** means the ARM plugin cross-compiles and loads and the connector rides the proven
  libpurple 2.14 + ssl-openssl (Teams-port) backend. **WhatsApp** (IM + calls) and **Signal** (IM)
  are verified end-to-end on device; Teams is the reference deployment; the rest are built but most
  have not yet been ticked off end-to-end on device.
- **Telegram** has the most advanced calling: TDLib signaling + libtgvoip media bridged to the
  stock Phone app — **calls connect with audio on device**; outbound mic capture hits the same
  **device-mic-specific** issue as WhatsApp (not a connector bug). No video.
- **Signal**: IM **works on device** (send/receive). Calling is second-most advanced: incoming
  calls ring the Phone app (signaling staged on device) and the SRTP-GCM + Opus **media loopback
  passes on device**; a real two-way call is still unverified.
- **WhatsApp**: IM works, and **voice calls work on device** via the `wacallm` media bridge —
  incoming/outgoing calls connect and audio flows. Outbound **mic capture is broken**, but that
  appears to be a **device-mic-specific** issue (the same symptom other calling connectors hit),
  not a WhatsApp-connector bug. No video.
- **Discord** calling is a **compiles/links/self-tests-on-ARM scaffold** (incl. the mandatory
  DAVE E2EE stack) that has **never completed a live voice handshake**.
- **Facebook**: the plain `purple-facebook` (email+password) is **retired** — it can't reach
  today's E2EE Messenger threads. The current path is `purple-gometa` (cookie auth, Signal-protocol
  E2EE), and **text IM now works**; attachment media is not yet wired up. Uses the original
  Facebook account icon.

## The transport reality (shapes the whole design)

The device `node` (`/usr/palm/nodejs/node`) links **OpenSSL 0.9.8k** and the stock webview is
WebKit ~2009 — **neither can complete a TLS 1.2/1.3 handshake**, so *no modern HTTPS can happen
in the webOS JS/node layer*. Every modern-TLS step is pushed out of JS:

- **All token/API/file calls shell out to a modern curl.** The companion **OpenSSL-11 update**
  now ships a modern **system curl** — `/usr/bin/curl` (curl 7.88.1 / OpenSSL 1.1.1w, TLS 1.3),
  verified doing TLS 1.2/1.3 to the cloud APIs on-device. Connectors set `CURL: "/usr/bin/curl"`
  with no `LD_LIBRARY_PATH` — **the old private `/var/dropbox-tls/` bundle is no longer required.**
- **OAuth login pages** that need modern TLS run in **Atlas** (WPE browser) via the customUI
  webview, not the stock account webview.
- **Public clients + PKCE** wherever the provider allows it (Dropbox/Box/OneDrive) — no
  `client_secret`, so the identical package ships to every device with nothing to provision.
  Providers that require a secret (Google/pCloud/Koofr/HiDrive/Yandex) ship it; token/SigV4/E2E
  connectors (kDrive/S3/MEGA) avoid OAuth entirely.
- **Crypto in JS uses node's core `crypto`** (OpenSSL 0.9.8k) — MEGA's E2E stack and S3's SigV4
  signer are built on it, with device-specific workarounds where 0.9.8k/node 0.4 fall short
  (e.g. MEGA derives AES-CTR from a native ECB keystream; PBKDF2 `digest()` returns a string).
- **Messaging** uses a vendored **libpurple 2.14 + ssl-openssl** backend cross-compiled for
  ARMv7, with an `imlibpurpleservice` SSL override so the plugins' native TLS loads.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full picture.

## Shared `_cloudcore` runtime

Newer cloud connectors share one byte-identical runtime, `cloud/cloudcore/service/_cloudcore/`
(generic `cloudservice.js` assistant + `oauth2.js` + `httpcurl.js` + generic commands), plus one
generic OAuth webview app `cloud/cloudcore/auth/com.palm.app.cloud-auth/`. A connector on this
runtime is **just two files** — its `config.js` (endpoints/credentials) and `adapter.js`
(provider REST).

- **On `_cloudcore`:** OneDrive, pCloud, Yandex-*(own service predates it)*, MEGA, Koofr,
  HiDrive, S3, kDrive. (OneDrive/pCloud/HiDrive use the shared `cloud-auth` webview; MEGA/Koofr/
  S3/kDrive ship their own credential-form app since they aren't OAuth-webview flows.)
- **Own standalone service** (predate cloudcore): Dropbox, Box, Google Drive, Yandex, Flickr.

## Layout

```
cloud/                                all cloud / file connectors + their shared runtime
  cloudcore/
    service/_cloudcore/               shared connector runtime (cloudservice/oauth2/httpcurl + commands)
    auth/com.palm.app.cloud-auth/     one generic OAuth webview app (drives Atlas login)
  dropbox/  box/  onedrive/  gdrive/   per-connector: service/ + apps/ (auth + files) + account/ template
  pcloud/  yandex/  mega/  koofr/
  hidrive/  s3/  kdrive/  flickr/
    <connector>/service/com.palm.service.<svc>/  config.js + adapter.js (on cloudcore) or full service
    <connector>/apps/…-auth/  …-files/           customUI sign-in + Enyo file-picker/manager
    <connector>/account/com.palm.<svc>.json      Synergy account template (DOCUMENTS / PHOTO.UPLOAD)
photos-integration/                   patches to stock com.palm.service.photos (+ recipe to add a source)
quickoffice-integration/              reroute QuickOffice's remote-file layer onto our services
docviewer/                            Atlas-hosted view-only viewer PoC (PDF/docx/xlsx + text/images)
messaging/                            libpurple IM connectors — see messaging/README.md
  imlibpurpleservice/                 shared libpurple <-> webOS bridge (used by all)
  teams/ telegram/ signal/ discord/   per-service: account/ + apps/ + plugin/ (+ calling/ where built)
  whatsapp/ googlechat/ facebook-e2ee/
recon/                                RE notes: facebook, linkedin, snapfish, google-drive, instagram, pcloud, yandex, flickr
device-setup/                         on-device font install, etc.
docs/ARCHITECTURE.md  docs/legal/     architecture + Privacy Policy / Terms (for OAuth app registration)
```

## Deployment prerequisites

The cloud connectors depend on the companion **OpenSSL-11 update** (deployment bundle — **not**
committed here) being on-device:

1. **A modern system curl** at `/usr/bin/curl` (curl 7.88.1 + OpenSSL 1.1.1w). All HTTPS shells
   out to it.
2. **A current CA store** at `/etc/ssl/certs/ca-certificates.crt`. The stock rootfs ships a 2011
   stub with no modern roots (e.g. ISRG Root X1), so a flashed/reset device can't verify a modern
   cloud cert until this is refreshed.
3. **The Atlas browser** (`org.webosports.app.atlas`, a WPE browser with modern TLS). The stock
   webview can't complete a modern TLS handshake, so every OAuth **login page** is hosted in
   Atlas — without it, OAuth-based connectors can't sign in.

With those in place: deploy a connector into `/usr/palm/…`, drop its account template + LS2 role
files, apply the `photos-integration/`/`quickoffice-integration/` patches as needed, restart the
accounts + photos services, and sign in via **Settings → Accounts**. Per-component READMEs have the
details. Messaging connectors have their own build/deploy scripts (ARM cross-compile) — see
[`messaging/README.md`](messaging/README.md).

## License / attribution

Original Palm/HP account-service code is **not** vendored here. Messaging plugin **source** is
vendored (built binaries are git-ignored) and tracks the upstream forks listed in
`messaging/README.md`. Everything under the cloud connectors and the account templates is new work.

Changes to the stock **core apps** (Photos / Messaging / Contacts / Phone) are **not** in this
repo — they live in the separate **core-apps** repository. Any app-level patches still present here
(e.g. `photos-integration/`) are superseded and stale; treat core-apps as the source of truth for
those apps.
