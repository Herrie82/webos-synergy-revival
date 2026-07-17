# Messaging connectors (libpurple)

Synergy **IM** account providers for webOS, alongside the cloud/file connectors. Each brings a
modern chat network back to the stock **Messaging** app via a `libpurple` protocol plugin bridged
into webOS by **imlibpurpleservice**.

| Service | Account template | App(s) | Protocol plugin | Notes |
|---|---|---|---|---|
| **Teams** | `com.palm.teams` | `com.palm.app.teams` | `purple-teams` | OAuth device-code → refresh_token as credential; silent re-login |
| **Discord** | `com.palm.discord` | `com.palm.app.discord`, `com.palm.app.discordqr` | `purple-discord` (+ `libqrencode` for QR login) | QR or paste-token sign-in |
| **Telegram** | `com.palm.telegram` | `com.palm.app.telegram` | `tdlib-purple` (+ `tdlib-src`) | **TDLib**-based; supersedes the older tgl `telegram-purple` |
| **Facebook** | `com.palm.facebookim` | `com.palm.app.facebookim` | `purple-facebook` | Plain email + password. Uses a distinct templateId — the stock dead `com.palm.facebook` template collides. Upstream fragile (2FA can't log in) |
| **Google Chat** | `com.palm.googlechat` | `com.palm.app.googlechat` | `purple-googlechat` (+ cross-built `libprotobuf-c`) | Auth via 5 pasted cookies → prpl protocol options; protobuf wire format |
| **WhatsApp** | `com.palm.whatsapp` | `com.palm.app.whatsapp` | `purple-gowhatsapp` (whatsmeow, Go `c-archive`) | Phone + QR/pairing link; pure-Go backend cross-compiled for arm; ~19 MB |
| **Signal** | `com.palm.signal` | `com.palm.app.signal` | `purple-signal` (+ cross-built OpenJDK 11 JRE, libsignal_jni, libzkgroup) | Fully built; embeds a JVM to drive signal-cli. On-device test pending. See below |

## Layout

```
messaging/
  imlibpurpleservice/        shared libpurple <-> webOS bridge service (used by all three)
  <service>/
    account/com.palm.<svc>/  account template + icons
    apps/com.palm.app.<svc>/ enyo Messaging integration app(s)
    plugin/<prpl>/           vendored protocol-plugin source (built binaries git-ignored)
    patched/                 (Teams) patches to stock on-device files
    *.sh / *.md              build + deploy scripts and notes
```

## Vendoring

Plugin **source** is vendored here; **built binaries** (`.so/.o/.a`, `build*/`) are git-ignored and
produced by each plugin's own build (ARM cross-compile — see the per-service `BUILD-LOG.md`). The
sources track these upstream forks:

- Teams — https://github.com/Herrie82/purple-teams (`herrie/teams-personal-fixes`)
- Discord — https://github.com/Herrie82/purple-discord (`herrie/fixes`)
- Telegram — `tdlib-purple` (ars3niy/tdlib-purple) linked against **TDLib** (`tdlib-src`)
- Facebook — https://github.com/dequis/purple-facebook (`master` @ `2c8038a`, 0.9.6)
- Google Chat — https://github.com/EionRobb/purple-googlechat (`master` @ `539e0cc`); `googlechat.pb-c.*`
  pre-generated (protoc-c 1.4.1) + protobuf-c runtime v1.4.1 vendored
- WhatsApp — https://github.com/hoehermann/purple-gowhatsapp (`whatsmeow` @ `4b75b6e`) + `scripts/purple-cmake`
  submodule; Go backend (`go.mau.fi/whatsmeow`, `modernc.org/sqlite`) fetched at build time
- `libqrencode`, `imlibpurpleservice` — vendored source

The Telegram plugin's `api_id`/`api_hash` in `tdlib-purple/CMakeLists.txt` is TDLib's **public
default** (`94575`), the same one shipped in TDLib's own examples — not a private credential.

The superseded tgl-based `telegram-purple` / `purple-telegram` and the abandoned build trees are
**not** vendored.

## Signal (built; on-device test pending)

`hoehermann/purple-signal` (`prpl-hehoe-signal`) is not a self-contained C plugin — its stack is
`C++ plugin → embedded JVM → signal-cli (Java) → Rust libsignal_jni.so`. Both hard pieces are now
**cross-compiled for webOS ARMv7**:
1. a softfp **OpenJDK 11** (Zero, headless) to host signal-cli — `signal/build-jvm.sh` (+ a ~25 MB
   `jlink`'d JRE in `build-output/openjdk-arm-jre/`); and
2. the pure-Rust **libsignal_jni** (libsignal-client `java-0.2.3`) + **libzkgroup** (zkgroup
   `v0.7.0`) — `signal/build-libsignal.sh`.
`signal/assemble-signal.sh` bundles the JRE + signal-cli jars (with the ARM natives swapped in) +
`purple_signal.jar` + the prpl (now linked against `libjvm.so`); `signal/deploy-signal.sh` ships
it. **Remaining: on-device end-to-end testing** — first real registration/link + JVM footprint on
the 1 GB device. Note the plugin is **archived (2022)** and pinned to signal-cli 0.8.0, which may
need updating if Signal's servers have moved on. See `signal/BUILD-LOG.md` for the full build.
