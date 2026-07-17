# Facebook prpl — build log

## Upstream / vendoring
- Source: **dequis/purple-facebook** `master` @ `2c8038a` (RELEASE_VERSION **0.9.6**),
  vendored verbatim under `plugin/purple-facebook/` (`.git` stripped; build artifacts gitignored).
- prpl id: **`prpl-facebook`** (`FB_PROTOCOL_ID` in `facebook.h`) — matches the generic
  imlibpurpleservice `type_facebook` → `prpl-facebook` transform, so **no LibpurpleAdapter
  override** was needed (unlike Teams' `prpl-teams-personal`).
- No git submodules; the libpurple headers it needs are the purple2 back-port shims in the
  repo's top-level `include/`.

## Toolchain / deps
- Cross toolchain: `~/x-tools/arm-unknown-linux-gnueabi-gcc125` via `~/webos/wpe/env-glibc-gcc125.sh`
  (armv7-a, neon, softfp).
- libpurple 2.14.13 staging: `messaging/libpurple/` (purple.pc).
- glib-2.0 / gobject / gio / json-glib-1.0 / zlib: `~/webos/wpe/staging-glibc-252`.

## Build approach — direct compile (not autotools)
Cross-configuring purple-facebook's autotools against the staged sysroot is fussy, so
`build-facebook.sh` compiles the fixed `FACEBOOKSOURCES` list directly, replicating the
flags from `configure.ac` / the plugin `Makefile.am`:

- `PLUGIN_CFLAGS = -I include -I pidgin -I pidgin/libpurple -I build-arm -DPURPLE_PLUGINS -include purple-compat.h`
  \+ `$(GLIB/JSON/PURPLE/ZLIB _CFLAGS)`.
- `marshal.{c,h}` generated from `marshaller.list` with the **host** `glib-genmarshal`
  (arch-independent), emitted into `build-arm/`.
- Sources: `marshal.c api.c data.c facebook.c http.c json.c mqtt.c thrift.c util.c`
  (in `protocols/facebook/`) + the purple2compat `../../http.c` and `../../purple-socket.c`
  (compiled to distinct object names to avoid the two `http.c` colliding).
- Link: `$GLIB_LIBS $JSON_LIBS $PURPLE_LIBS $ZLIB_LIBS` (TLS via libpurple's SSL plugin).

### Two fixups vs a stock `/usr` autotools build
1. **`-I$PURPLE/include`** added: the compat headers use `<libpurple/util.h>`, which needs
   the include *root* on the path; purple.pc only supplies `-I<prefix>/include/libpurple`
   (bare names). Implicit on a `/usr` install, explicit for our staged prefix.
2. **`-DPACKAGE_VERSION="0.9.6" -DPACKAGE_URL="https://github.com/dequis/purple-facebook"`**:
   normally provided by autotools' `config.h` (from `AC_INIT`); injected on the command line
   since we skip `configure`. (`PACKAGE_VERSION` → api.h User-Agent; `PACKAGE_URL` → facebook.c
   `info.homepage`.) Version is read from `RELEASE_VERSION`.

## Result
- Output: `build-arm/libfacebook.so` (229 KB) → stripped `libfacebook.stripped.so` (168 KB).
- `readelf -h`: ELF32, **ARM**, DYN. Exports `purple_init_plugin` (×1).
- Embeds `prpl-facebook`, `Facebook plugin / Purple / 0.9.6 …`.
- `NEEDED`: `libpurple.so.0`, `libjson-glib-1.0.so.0`, `libgio-2.0.so.0`, `libgobject-2.0.so.0`,
  `libglib-2.0.so.0`, `libz.so.1`, `libc.so.6` — all present on-device (json-glib was staged for
  Discord; glib/gio/z in the base system). No new backend runtime deps to stage.
- Only compiler *warnings*: deprecated `g_memdup` (harmless on this glib); no errors.

## Deploy
`deploy-facebook.sh` pushes the customUI app (`com.palm.app.facebook`), the account template
(`com.palm.facebook`, rootfs rw) and drops `libfacebook.stripped.so` → `libfacebook.so` into the
live backend `…/backend/lib/purple-2/`. Then Add Account → Facebook (email + password).
