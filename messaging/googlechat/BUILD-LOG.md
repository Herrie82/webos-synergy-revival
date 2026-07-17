# Google Chat prpl — build log

## Upstream / vendoring
- Source: **EionRobb/purple-googlechat** @ `539e0cc`, vendored under `plugin/purple-googlechat/`
  (`.git` stripped; build artifacts gitignored). `purple2compat/` is vendored in-tree (like
  purple-discord); no git submodules.
- prpl id: **`prpl-googlechat`** (`GOOGLECHAT_PLUGIN_ID`) — matches the generic
  `type_googlechat → prpl-googlechat` transform, **no LibpurpleAdapter override**.

## The protobuf-c dependency (the one thing beyond Facebook)
Google Chat speaks protobuf, so the plugin needs both the protobuf-c **codegen** (build time)
and the protobuf-c **runtime** (link/runtime):
- **Codegen**: `googlechat.pb-c.{c,h}` were generated once with **protoc-c 1.4.1** from the
  in-tree `googlechat.proto` and **vendored** (generated C is arch-independent), so the ARM
  build needs no host `protoc-c`.
- **Runtime**: the protobuf-c runtime is a single TU. Its source (`protobuf-c.c` + header,
  v1.4.1) is vendored under `protobuf-c-runtime/`, and `build-googlechat.sh` cross-compiles it
  to `libprotobuf-c.so.1`, then links the plugin against it.

## Build approach — direct compile (like Facebook)
`build-googlechat.sh` compiles the upstream Makefile's source list directly with the ARM
toolchain (`arm-unknown-linux-gnueabi-gcc125`), replicating its flags:
- sources: `libgooglechat.c googlechat.pb-c.c googlechat_json.c googlechat_pblite.c
  googlechat_connection.c googlechat_auth.c googlechat_events.c googlechat_conversation.c`
  \+ `purple2compat/http.c purple2compat/purple-socket.c`.
- cflags: `-I. -Ipurple2compat -Iprotobuf-c-runtime` + `pkg-config purple glib-2.0 json-glib-1.0 zlib`.
- link: those pkgs + `-lprotobuf-c` (our cross-built runtime). TLS via libpurple's SSL plugin.

## Result
- `build-arm/libgooglechat.stripped.so` (~700 KB), ELF32 **ARM**, exports `purple_init_plugin`,
  embeds `prpl-googlechat`. Plus `libprotobuf-c.stripped.so` (~30 KB).
- `NEEDED`: `libprotobuf-c.so.1`, `libpurple.so.0`, `libjson-glib-1.0.so.0`, `libgio/gobject/glib`,
  `libz.so.1`, `libc.so.6` — all satisfiable on-device (json-glib staged for Discord; we deploy
  libprotobuf-c.so.1 alongside the plugin; rest are base).

## Auth wiring
Five cookies (COMPASS/SSID/SID/OSID/HSID) → the setup app returns them in the account `config`
under the prpl's option keys (`COMPASS_token`, `SSID_token`, `SID_token`, `OSID_token`,
`HSID_token`). imlibpurple's `Util::createPurpleAccount` walks the prpl's `protocol_options` and
sets each matching `config` key via `purple_account_set_string`, so the cookies reach the prpl on
connect. `username` = the Google email (identity); password is an unused non-empty sentinel.

## Deploy
`deploy-googlechat.sh` pushes the setup app, the account template, `libprotobuf-c.so.1` (into
`backend/lib/`) and `libgooglechat.so` (into `backend/lib/purple-2/`).
