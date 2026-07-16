# purple-discord cross-compile for webOS ARMv7 (HP TouchPad)

Cross-compiled the EionRobb `purple-discord` libpurple plugin for webOS ARMv7,
reusing the already-built libpurple 2.14.13 backend from the Teams port.

Date: 2026-07-14
Result: **SUCCESS** — loadable ARM `.so` exporting `purple_init_plugin`.

## Environment

```bash
source ~/webos/wpe/env-glibc-gcc125.sh
export PKG_CONFIG_PATH=~/webos/teams-port/deploy/purple/lib/pkgconfig:~/webos/wpe/staging-glibc-252/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
```

- `$CC` = `arm-unknown-linux-gnueabi-gcc` (x-tools gcc 12.5, sysroot glibc 2.23)
- `pkg-config --exists purple glib-2.0 json-glib-1.0 zlib` → DEPS-OK
- libpurple: `~/webos/teams-port/deploy/purple` (2.14.13, purple.pc)
- glib/json-glib/zlib: `~/webos/wpe/staging-glibc-252`

## Steps & commands

### 1. Clone
```bash
cd ~/webos/discord-port/src && git clone https://github.com/EionRobb/purple-discord
```
Clone OK (HEAD 681f0f8).

### 2. Patch plugin id
`libdiscord.c` line 60, macro `DISCORD_PLUGIN_ID`, changed from upstream
`"prpl-eionrobb-discord"` to `"prpl-discord"` so it matches the webOS
transport's generic `type_discord -> prpl-discord` mapping.

(Line 87 defines the *Fluxer* override id `prpl-eionrobb-fluxer` under
`DISCORD_PLUGIN_OVERRIDE == 100`; that build path is not used, left untouched.)

Verification:
```
$ grep -n 'DISCORD_PLUGIN_ID "' libdiscord.c
60:#define DISCORD_PLUGIN_ID "prpl-discord"
87:#define DISCORD_PLUGIN_ID "prpl-eionrobb-fluxer"
```

### 3. Build

First attempt:
```bash
make CC="$CC" libdiscord.so
```
**FAILED** — the EionRobb Makefile enables `USE_QRCODE_AUTH` by default
(`ifneq ($(USE_QRCODE_AUTH),0)`), which pulls in `nss` and `libqrencode`
via pkg-config and includes `<qrencode.h>`:
```
discord_rsa.c:127:10: fatal error: qrencode.h: No such file or directory
```
Those deps are not available (and not wanted) for the webOS transport.

Fix — disable QR-code auth:
```bash
make CC="$CC" USE_QRCODE_AUTH=0 libdiscord.so
```
**SUCCESS.** Final compile line:
```
arm-unknown-linux-gnueabi-gcc -fPIC -march=armv7-a -mtune=cortex-a8 -mfpu=neon \
  -mfloat-abi=softfp -O2 -D_DEFAULT_SOURCE -std=c99 \
  -DDISCORD_PLUGIN_VERSION='"0.9.2026.07.14.git.681f0f8"' -DMARKDOWN_PIDGIN \
  -DENABLE_NLS -DLOCALEDIR=\"...\" -I.../staging-glibc-252/include \
  -shared -o libdiscord.so libdiscord.c markdown.c \
  purple2compat/http.c purple2compat/purple-socket.c \
  -L.../staging-glibc-252/lib -Wl,-rpath-link,.../staging-glibc-252/lib \
  `pkg-config purple glib-2.0 json-glib-1.0 zlib --libs --cflags` -Ipurple2compat -g -ggdb
```

No compat-header patching was needed: the repo already vendors `glib_compat.h`,
`json_compat.h`, `purple_compat.h`, and the `purple2compat/` dir, and the
Makefile already passes `-Ipurple2compat`. Behaved like the purple-teams build.

## Patches applied (total)
1. `libdiscord.c:60` plugin id `prpl-eionrobb-discord` -> `prpl-discord`.
2. Build-time flag only (not a source change): `USE_QRCODE_AUTH=0`.

No system libs or shared backend sources were modified.

## 4. Verification

```
$ file libdiscord.so
libdiscord.so: ELF 32-bit LSB shared object, ARM, EABI5 version 1 (SYSV),
  dynamically linked, with debug_info, not stripped

$ arm-unknown-linux-gnueabi-nm -D libdiscord.so | grep -c purple_init_plugin
1

$ arm-unknown-linux-gnueabi-nm -D libdiscord.so | grep ' U ' | wc -l
413
```

### Undefined-symbol resolution
All 413 undefined (`U`) symbols were cross-checked against:
- libpurple 2.14.13 (`~/webos/teams-port/deploy/purple/lib/libpurple.so.0.14.13`)
- staging glib / json-glib / zlib (`~/webos/wpe/staging-glibc-252/lib`)
- toolchain sysroot libc/libm/libpthread (glibc 2.23) + libintl

**Unresolved against nowhere: 0.**

The only symbols not found in libpurple/glib/json-glib are standard
libc/libm/libintl symbols, all satisfied by the target system at runtime:
`bindtextdomain`, `bind_textdomain_codeset`, `close`, `__errno_location`,
`__isoc99_sscanf`, `memcpy`, `raise`, `read`, `remainder`, `strchr`, `strcmp`,
`strlen`, `strncmp`, `strrchr`, `strstr`, `strtol`, `time`, `trunc`, `write`
— all confirmed present in the sysroot libc/libm.

## 5. Output artifacts

- `~/webos/discord-port/src/purple-discord/libdiscord.so` (898332 bytes)
- `~/webos/teams-port/deploy/purple/lib/purple-2/libdiscord.so` (898332 bytes)

sha256 (identical): `d2ba49afd7fa4d2877ea29ba543d49a5008e530b01e29907cb43dc56b4f74018`

Plugin id confirmed: **`prpl-discord`**.
