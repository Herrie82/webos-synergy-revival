# WhatsApp prpl — build log

## Upstream / vendoring
- Source: **hoehermann/purple-gowhatsapp** `whatsmeow` branch @ `4b75b6e`, vendored under
  `plugin/purple-gowhatsapp/` (`.git` stripped; build artifacts gitignored). One submodule,
  `scripts/purple-cmake` (CMake tooling), vendored in.
- Backend: **whatsmeow** (`go.mau.fi/whatsmeow`) — the modern multi-device WhatsApp library.
- prpl id: **`prpl-hehoe-whatsmeow`**. The `hehoe`/`whatsmeow` names can't be derived from the
  db8 service name, so `type_whatsapp → prpl-hehoe-whatsmeow` is mapped explicitly in
  imlibpurpleservice `LibpurpleAdapter.cpp` (next to Teams/Signal).

## Why this one cross-compiles (the pleasant surprise)
purple-gowhatsapp is a C libpurple plugin wrapping a **Go** backend built as a `c-archive`.
Cross-compiling Go is usually easy, and here it's genuinely clean because the whole WhatsApp
stack is **pure Go**:
- `go.mau.fi/whatsmeow` (crypto/Noise/protobuf all pure Go), and
- its store uses **`modernc.org/sqlite`** — a **pure-Go** SQLite, not `mattn/go-sqlite3`, so
  there is **no C SQLite to cross-compile**. modernc sqlite supports `linux/arm GOARM=7`.
The only cgo C files are `bridge.c`/`constants.c`/`opusreader.c`, compiled by the cross gcc.

## Build approach — direct (the upstream CMake has no cross plumbing)
`build-whatsapp.sh` reproduces the CMake in three stages with the ARM toolchain:

1. **Go c-archive** — `GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=1 CC=arm-…-gcc go build
   -buildmode=c-archive -o libwhatsmeow.a`, with `CGO_CFLAGS/CGO_LDFLAGS` pointed at the ARM
   libpurple + opus/opusfile. Produces `libwhatsmeow.a` (~42 MB) + `libwhatsmeow.h`. Needs a
   **Go 1.25+** host toolchain (go.mod `go 1.25.5`) and network to fetch modules the first time.
2. **C glue** — compile `glue/*.c` + root `bridge.c`/`constants.c`. `gdk-pixbuf` is optional:
   `pixbuf.c` is guarded by `#if __has_include("gdk-pixbuf/gdk-pixbuf.h")`, so we simply omit it
   from the include path and it takes the no-pixbuf fallback (image-format sniffing disabled).
3. **Link** `libwhatsmeow.so` = glue objects + `libwhatsmeow.a` + libpurple + opusfile/opus/ogg
   \+ the Go runtime's system deps (`-lpthread -ldl -lm -lresolv`).

### opusfile
`opusreader.c` (voice-note transcoding) needs libopusfile. opus + ogg are already in the WPE
staging; **libopusfile was cross-compiled** from xiph/opusfile against them and installed into
staging. All three are staged on-device by the deploy script.

## Result
- `build-arm/libwhatsmeow.stripped.so` (~19 MB — the Go runtime is statically linked), ELF32
  **ARM**, exports `purple_init_plugin`, embeds `prpl-hehoe-whatsmeow`.
- `NEEDED`: `libpurple.so.0`, `libglib-2.0.so.0`, `libopusfile.so.0`, `libopus.so.0`,
  `libogg.so.0`, `libpthread.so.0`, `libdl.so.2`, `libm.so.6`, `libresolv.so.2`, `libc.so.6` —
  all satisfiable on-device (opus/ogg from WPE, opusfile staged by deploy, rest base).
- **Footprint note**: ~19 MB `.so` + the Go runtime's RSS (GC heap, multiple OS threads) is
  heavy for a 2011 1 GB device — the main runtime concern to watch when testing.

## Auth
Multi-device: phone number up front (setup app) → QR link or 8-char pairing code surfaced by the
prpl on connect and completed from the Messaging app. whatsmeow persists its session in the prpl
account store after the first link.

## Deploy
`deploy-whatsapp.sh` pushes the setup app, the account template, the opus/ogg/opusfile libs (into
`backend/lib/`) and `libwhatsmeow.so` (into `backend/lib/purple-2/`).
