# purple-gometa — Facebook Messenger (with E2EE) as a libpurple prpl

Status: **scaffold + login spike** (compiles host + armv7). Prpl glue not written yet.

## Why this exists

Legacy `purple-facebook` (dequis) speaks Facebook's ~2015 MQTT protocol and **cannot
send to end-to-end-encrypted threads** — Facebook rejects them with
`errno 1545116 "This thread is disabled"`. FB made E2EE the default across Messenger
(~2023–24), so most threads now fail; only old non-E2EE threads still send (see the
project memory `facebook-ssl-openssl-loader-fix` / `facebook-e2ee-gometa-port`). This is a
protocol gap, not a bug — upstream purple-facebook is maintenance-only and won't get E2EE.

The only realistic path to modern FB send is the **current** Meta protocol, which is
implemented in Go by [mautrix-meta](https://github.com/mautrix/meta) via its `messagix`
package (+ `whatsmeow` for the Signal-protocol E2EE transport — Messenger E2EE rides
WhatsApp's infrastructure).

## Architecture (mirrors the working WhatsApp plugin)

Build a Go package that imports `go.mau.fi/mautrix-meta/pkg/messagix`, implements the
libpurple prpl callbacks via cgo, and links as a `.so` — exactly like
`../../../whatsapp/plugin/purple-gowhatsapp/` wraps `go.mau.fi/whatsmeow` into
`libwhatsmeow.so`. Two-stage build: `go build -buildmode=c-archive` → `libgometa.a`,
then C glue links it into `libgometa.so`.

```
messagix  (Meta account/session, lightspeed inbox, non-E2EE send)
whatsmeow (E2EE transport — cli.PrepareE2EEClient() returns a *whatsmeow.Client)
   │  both PURE GO — cross-compile armv7 clean, no native libsignal FFI
   ▼
purplegometa (Go prpl callbacks) ──cgo──▶ libpurple prpl  ──▶ imlibpurpletransport
```

## Feasibility spike — PASSED (2026-07-19)

- `messagix` cross-compiles `GOOS=linux GOARCH=arm GOARM=7` — pure-Go (CGO=0), cgo, and
  **`buildmode=c-archive`** (the prpl form). No cgo SQLite, no native deps.
- Auth is **cookie-based** (`c_user`, `xs`, `datr` required) — not username/password.
- E2EE stack is pure Go: `go.mau.fi/whatsmeow` + `go.mau.fi/libsignal`.

### go.mod gotcha
mautrix-meta pins a **Beeper fork of `imroc/req/v3`** via a `replace` directive. Go does
**not** inherit a dependency's `replace`, so this module mirrors it in its own `go.mod`
(the `replace github.com/imroc/req/v3 => github.com/beeper/req/v3 …` line). Without it the
build fails in `imroc/req/v3/internal/http3` (qpack API mismatch).

## The login spike (`login-spike/`)

Drives the `messagix` client directly — no Matrix bridge — to (1) confirm `messagix` is
usable as a standalone library ([mautrix/meta#104](https://github.com/mautrix/meta/issues/104))
and (2) map the login/session surface. Stages: load cookies → `LoadMessagesPage` (auth +
inbox) → `Connect` (lightspeed socket) → `WaitUntilCanSendMessages` → `PrepareE2EEClient`
(whatsmeow) → log the concrete type of every realtime event (the surface the prpl must map).

### Get cookies
Log into `facebook.com` in a browser, open DevTools → Application → Cookies, and copy the
values into a flat JSON file:

```json
{"c_user":"100...","xs":"...","datr":"...","sb":"...","fr":"...","wd":"1920x1080"}
```

### Run (on the host first — fast, has network)
```sh
export GOPATH=/home/herrie/webos/gotool/gopath GOCACHE=/home/herrie/webos/gotool/gocache GOMODCACHE=/home/herrie/webos/gotool/gomod
/home/herrie/webos/gotool/go125/bin/go run ./login-spike cookies.json
```
A clean run prints `AUTH OK`, `connected=true`, `SEND-READY`, and an enumerated list of
event types. That green-lights writing the prpl glue.

## Next steps (not done)
1. Run the login spike with real cookies → confirm standalone usability + map events.
2. Scaffold the prpl root package (`bridge.go`/`bridge.c` + `login.go`/`send_message.go`/
   `handle_message.go`) from `purple-gowhatsapp`; wire `build-meta.sh`.
3. Minimal prpl: register protocol → login (cookies) → receive → send (E2EE via whatsmeow).
4. Account-setup app + template (collect cookies) mirroring the other services.
