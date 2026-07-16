# Telegram libpurple plugin — webOS ARMv7 cross-build log

Target: `arm-unknown-linux-gnueabi` (ARMv7, cortex-a8, NEON, softfp), glibc, gcc 12.5.0
libpurple: 2.14.13 (prebuilt at `~/webos/teams-port/deploy/purple`)
Date: 2026-07-14

## Environment
```bash
source ~/webos/wpe/env-glibc-gcc125.sh
export PKG_CONFIG_PATH=~/webos/teams-port/deploy/purple/lib/pkgconfig:~/webos/wpe/staging-glibc-252/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
```
Sanity: `pkg-config --exists purple glib-2.0 json-glib-1.0 zlib` -> DEPS-OK
Available target libs: purple 2.14.13, glib 2.70.5, json-glib 1.6.6, zlib 1.3.1,
libgcrypt 1.10.3, gpg-error 1.47, libwebp 1.3.2, libpng16.

## Phase A — telegram-purple (github.com/majn/telegram-purple)

Repo cloned with `--recursive` (submodule `tgl` @ 0d07cea). Note: majn repo is
officially ABANDONED (README points to tdlib-purple); uses old MTProto layer.
Plugin id is `prpl-telegram`. Uses libgcrypt (preferred) + zlib + libwebp + libpng.

### Configure
```
./configure --host=arm-unknown-linux-gnueabi --prefix=/usr --disable-translation
```
Result: SUCCESS. Found PURPLE, gcrypt (gcry_mpi_snatch), webp, png, zlib.
CRYPTO_FLAG set to --disable-openssl (build against libgcrypt).
Warning (benign): "using cross tools not prefixed with host triplet" (pkg-config).

### Build (make) — errors encountered & fixes

**Error 1 — tgl subconfigure cannot cross-compile.**
`make` invokes `cd tgl && ./configure ...` WITHOUT `--host`, so tgl's configure
tried to run an ARM test binary: `configure: error: cannot run C compiled programs`.
Fix: patched generated `Makefile` line 130 to add `--host=arm-unknown-linux-gnueabi`
to the tgl configure invocation.

**Error 2 — TL code generator must run on the host (the classic blocker).**
tgl builds host tools `bin/tl-parser` and `bin/generate` from the TL schema and
RUNS them at build time to emit `auto/*.c`. Cross-built for ARM, they can't run:
`arm-binfmt-P: Could not open '/lib/ld-linux.so.3'` (no qemu/loader).
Fix (host-built TL generator): copied `tgl/` to scratchpad, cleaned it, ran a fully
NATIVE build (`env -i ... ./configure --disable-extf` using host gcc + host OpenSSL,
since host lacks libgcrypt-dev but has openssl-dev; the generated `auto/*` sources
are crypto-independent). Native build produced all `auto/*.c`, `auto/*.h`,
`constants.h`, `scheme.tlo`, `scheme2.tl`. Transplanted these into the cross tree's
`tgl/auto/`. Then patched `tgl/Makefile` generation rules (scheme.tl(o), scheme2.tl,
auto.c, auto-%.c/.h, constants.h) into `@touch $@` no-ops (dropping the
`bin/tl-parser`/`bin/generate` prerequisites) so cross-make treats the pre-generated
sources as final and never tries to run the ARM tools.

**Error 3 — host header pollution.**
tgl's configure baked `-I/usr/local/include -I/usr/include` into `CPPFLAGS`, so the
ARM compile pulled in host glibc `stdlib.h`: `error: '_Float128' is not supported on
this target`. Fix: edited `tgl/Makefile` `CPPFLAGS` to only
`-I<staging-glibc-252>/include` (which provides gcrypt.h, gpg-error.h, zlib.h).

After these three fixes, `make` completed cleanly (only a benign
`-Wmissing-field-initializers` warning for `get_cb_alias`). Output:
`tgl/libs/libtgl.a` (static) linked into `bin/telegram-purple.so`.

### Verification — PASS
```
$ file libtelegram.so
ELF 32-bit LSB shared object, ARM, EABI5 version 1 (SYSV), dynamically linked,
with debug_info, not stripped
$ arm-...-nm -D libtelegram.so | grep -c purple_init_plugin   -> 1
$ strings libtelegram.so | grep prpl-telegram                 -> prpl-telegram  (plugin id)
```
Undefined-symbol check vs libpurple.so.0.14.13 + staging (glib, gobject, gmodule,
png16, webp, z, gcrypt, gpg-error) + sysroot libc/libm/pthread/rt/dl:
332 required, 7687 provided. UNRESOLVED = only 3, all WEAK/optional and always
undefined at link time (harmless): `__gmon_start__`, `_ITM_registerTMCloneTable`,
`_ITM_deregisterTMCloneTable`.
NEEDED: libpurple.so.0, libglib-2.0.so.0, libpng16.so.16, libwebp.so.7, libz.so.1,
libgcrypt.so.20, librt.so.1, libc.so.6, ld-linux.so.3 — all present on target/staging.

### Artifact
- Size: 4,041,848 bytes (unstripped; debug_info present — can be stripped for device).
- Plugin id: `prpl-telegram` (matches `type_telegram`).
- Copied to:
  - `~/webos/telegram-port/src/purple-telegram/libtelegram.so`
  - `~/webos/teams-port/deploy/purple/lib/purple-2/libtelegram.so`

### PHASE A RESULT: **SUCCESS** (build artifact produced).

**Connectivity caveat:** telegram-purple/tgl speaks an OLD MTProto layer that
Telegram has been deprecating. The .so loads and is a valid prpl, but LOGIN MAY FAIL
against current Telegram servers. For reliable present-day connectivity, Phase B
(tdlib-purple on official TDLib) is the correct long-term target.

## Phase B — tdlib-purple (tdlib) — NOT ATTEMPTED (time-boxed out)

Phase A produced the required deliverable. Phase B (tdlib-purple) requires a full
C++ ARM cross-build of TDLib, which itself needs a HOST-built TL generator
(`td/generate` / `tdc`) plus target OpenSSL + zlib, then a cmake build of
tdlib-purple against it — a multi-hour effort with high risk of not finishing in one
session (exactly the tradeoff flagged in the task). Deferred as an acceptable
outcome; telegram-purple from Phase A is the working fallback deliverable. If pursued
later: build TDLib's `tdtl`/generator natively first (same host-generator pattern
used to solve Phase A Error 2), cross-build libtdjson against staging OpenSSL/zlib,
then `cmake` tdlib-purple with `-DTd_DIR=...`, patch its plugin id to `prpl-telegram`,
and output `libtelegram.so`.

**Phase B recon (time-boxed, no build launched):** No prebuilt TDLib exists anywhere
in `~/webos` (`libtdjson*`/`TdConfig.cmake` absent). Prerequisites that DO exist:
target OpenSSL 3.0.16 + zlib in staging, host `cmake` and `gperf`. The remaining gap
is TDLib itself — its host TL-generator step plus the heavy C++ ARM cross-compile —
which is the multi-hour, high-risk portion and was deliberately deferred.
