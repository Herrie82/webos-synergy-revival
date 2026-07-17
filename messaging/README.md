# Messaging connectors (libpurple)

Synergy **IM** account providers for webOS, alongside the cloud/file connectors. Each brings a
modern chat network back to the stock **Messaging** app via a `libpurple` protocol plugin bridged
into webOS by **imlibpurpleservice**.

| Service | Account template | App(s) | Protocol plugin | Notes |
|---|---|---|---|---|
| **Teams** | `com.palm.teams` | `com.palm.app.teams` | `purple-teams` | OAuth device-code → refresh_token as credential; silent re-login |
| **Discord** | `com.palm.discord` | `com.palm.app.discord`, `com.palm.app.discordqr` | `purple-discord` (+ `libqrencode` for QR login) | QR or paste-token sign-in |
| **Telegram** | `com.palm.telegram` | `com.palm.app.telegram` | `tdlib-purple` (+ `tdlib-src`) | **TDLib**-based; supersedes the older tgl `telegram-purple` |
| **Facebook** | `com.palm.facebook` | `com.palm.app.facebook` | `purple-facebook` | Plain email + password; reuses on-device json-glib. Upstream fragile — 2FA accounts can't log in |
| **Signal** | `com.palm.signal` _(scaffold)_ | `com.palm.app.signal` | `purple-signal` | Builds (jar + ARM .so) but can't run yet: needs a modern ARMv7 JVM + Rust libsignal. See below |

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
- `libqrencode`, `imlibpurpleservice` — vendored source

The Telegram plugin's `api_id`/`api_hash` in `tdlib-purple/CMakeLists.txt` is TDLib's **public
default** (`94575`), the same one shipped in TDLib's own examples — not a private credential.

The superseded tgl-based `telegram-purple` / `purple-telegram` and the abandoned build trees are
**not** vendored.

## Signal (deferred)

`hoehermann/purple-signal` (`prpl-hehoe-signal`) is vendored and scaffolded (`signal/`), and it
**builds** — the Java jar compiles on a host JDK and all 18 C++ TUs cross-compile into a valid
ARM `purple-signal.so`. It just **can't run on-device yet**, because it is not a self-contained C
plugin: its stack is `C++ plugin → embedded JVM → signal-cli (Java) → Rust libsignal_jni.so`.
Two heavy (but not fundamentally walled) sub-projects remain:
1. a **modern Java-11+ `libjvm.so` cross-built for armv7 / glibc-2.23** — a JVM has run on webOS
   armv7 before, but the old homebrew builds are too old for signal-cli 0.8.0; and
2. the **Rust `libsignal_jni`** (moderate — pure-Rust, official std for the target, pinned
   `nightly-2020-11-09`).

The repo is also **archived (2022)** and pinned to signal-cli 0.8.0. The lighter long-term path is
a JVM-free native prpl on Rust `libsignal` (sub-project 2 only). See `signal/BUILD-LOG.md` for the
full attempt log, versions, and evidence.
