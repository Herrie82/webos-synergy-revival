# Proton Drive — recon

**Verdict: FEASIBLE ONLY as a cross-compiled native Go helper — NOT as a pure-JS `_cloudcore`
connector. Not built. Would be the hardest provider here (harder than MEGA), with real
first-login and API-drift risk.**

Proton Drive is zero-knowledge OpenPGP end-to-end encryption. Every crypto layer collides with the
device runtime (`node 0.4.12` / OpenSSL 0.9.8k, ES5 WebKit ~2009), so the MEGA-style
"pure-JS + node `crypto` + curl" approach that every other cloud connector uses is **off the
table**. The only realistic path mirrors the **messaging** side (whatsmeow `c-archive`, `wacallm`,
Signal's Rust/JVM natives): a pure-Go binary cross-compiled for webOS ARMv7 that carries its own
modern TLS + crypto, shelled out to from a thin adapter.

## Why the pure-JS path (MEGA-style) does NOT work

| Layer | Proton uses | Device reality |
|---|---|---|
| Login KDF | **Argon2id** (64 MB, 3 iterations, parallelism 4) — *memory-hard by design* | MEGA's PBKDF2 already ~23 s on device; a pure-JS Argon2id needing 64 MB scratch on a 1 GB TouchPad is effectively a non-starter |
| Auth | **SRP** (Secure Remote Password) | Doable in pure JS (bignum modPow, like MEGA) — the one tractable piece |
| Key exchange | **Curve25519 / X25519 + Ed25519** (default since 2023; older accounts RSA-4096) | Device has **no native ECC** — would need hand-rolled X25519/Ed25519 in ES5 |
| File content | **AES-256-GCM** content key, files split into **4 MB signed chunks** | MEGA already had to synthesize AES-CTR from raw ECB (`aes-128-ctr` missing); GCM/GHASH would need a pure-JS implementation |
| Envelope | Full **OpenPGP** packet layer (SEIPD, S2K, key/session packets) + Proton's share→node→content key hierarchy | No mature **ES5** OpenPGP.js supports Curve25519 (ECC landed in OpenPGP.js *after* it dropped old-engine support) |

Net: the pure-JS route means reimplementing Argon2id + X25519/Ed25519 + AES-GCM + an OpenPGP
message layer from scratch on a 2011 engine, against an **undocumented, reverse-engineered**
protocol that Proton changes. Impractical.

## The viable path: native Go helper

- **[henrybear327/Proton-API-Bridge](https://github.com/henrybear327/Proton-API-Bridge)** (pure
  Go) + `proton-go-api` + `go-srp` + `gopenpgp` is what powers **rclone's Proton Drive backend**
  (<https://rclone.org/protondrive/>). It already handles SRP login, the key hierarchy, and E2E
  decrypt/encrypt. Pure Go → **cross-compiles to webOS ARMv7 cleanly** (whatsmeow proves the
  toolchain).
- Shape: build a small Go helper (or vendor rclone's `protondrive` backend / `proton-go-api`
  directly), shell out to it from a thin DOCUMENTS (+ maybe PHOTO.UPLOAD) adapter for
  list/download/upload. The device JS never touches Proton's crypto or TLS — the Go binary carries
  gopenpgp + its own modern OpenSSL.

Caveats:
- **Breaks the cloud connectors' pure-JS ethos** — but not unprecedented in this repo, which
  already ships native Go/Rust/JVM binaries on the messaging side.
- The bridge repo was **archived read-only 2026-02-05** — build against rclone's still-maintained
  `protondrive` backend or `proton-go-api` instead.
- Easy login path is **username + password only — no 2FA, no legacy 2-password mode** in the V1
  bridge. **CAPTCHA / human-verification** can block a headless first login from a new device IP.
- **Unofficial API** — breaks when Proton changes the backend (a recurring rclone-forum theme).

## On the official SDK (Jan 2026)

- Repo **[ProtonDriveApps/sdk](https://github.com/ProtonDriveApps/sdk)** — TypeScript/JS + C# (+
  Swift/Kotlin bindings), **MIT**. Powers Proton's own clients.
- **Does not help yet:** "Authentication and other Proton-specific modules required for standalone
  third-party integrations are **not yet supported** … not for third-party production use." It's TS
  on WebCrypto, so it wouldn't run on the device engine regardless. Proton lists a "single,
  well-documented integration path" as a 2026 goal — worth watching, not actionable now.
- Still useful as an **authoritative reference** for the protocol/crypto (vs. pure RE), if a build
  is attempted.

## Prior art (Ubuntu / Sailfish / Linux)

Nobody reimplemented the protocol natively for a lightweight client. The "Linux clients"
([DonnieDice/protondrive-linux](https://github.com/DonnieDice/protondrive-linux), Celeste, Tauri
wrappers) either **wrap Proton's web app in a WebKitGTK/Tauri window** or **shell out to rclone**
(Celeste). Proton's own upcoming Linux client is WebKitGTK on the new SDK. The only real
native-protocol prior art is the **rclone / Go bridge** — which points straight back to the
Go-helper path above.

## If activated

1. Cross-compile a Go helper on rclone's `protondrive` backend / `proton-go-api` for webOS ARMv7
   (reuse the messaging Go toolchain).
2. Wrap it in a minimal adapter exposing list/download/upload (DOCUMENTS; PHOTO.UPLOAD optional).
3. Sign in with username+password; expect to have to handle **CAPTCHA / 2FA** friction on first
   login, and budget for **API drift**.

Budget this as the single hardest connector in the repo. See [`../cloud/mega/README.md`](../cloud/mega/README.md)
for how far the pure-JS crypto approach can be pushed — Proton is a step beyond where that
approach is viable.
