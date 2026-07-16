# Messaging connectors (libpurple)

Synergy **IM** account providers for webOS, alongside the cloud/file connectors. Each brings a
modern chat network back to the stock **Messaging** app via a `libpurple` protocol plugin bridged
into webOS by **imlibpurpleservice**.

| Service | Account template | App(s) | Protocol plugin | Notes |
|---|---|---|---|---|
| **Teams** | `com.palm.teams` | `com.palm.app.teams` | `purple-teams` | OAuth device-code → refresh_token as credential; silent re-login |
| **Discord** | `com.palm.discord` | `com.palm.app.discord`, `com.palm.app.discordqr` | `purple-discord` (+ `libqrencode` for QR login) | QR or paste-token sign-in |
| **Telegram** | `com.palm.telegram` | `com.palm.app.telegram` | `tdlib-purple` (+ `tdlib-src`) | **TDLib**-based; supersedes the older tgl `telegram-purple` |

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
- `libqrencode`, `imlibpurpleservice` — vendored source

The Telegram plugin's `api_id`/`api_hash` in `tdlib-purple/CMakeLists.txt` is TDLib's **public
default** (`94575`), the same one shipped in TDLib's own examples — not a private credential.

The superseded tgl-based `telegram-purple` / `purple-telegram` and the abandoned build trees are
**not** vendored.
