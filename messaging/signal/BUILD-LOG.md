# Signal prpl — build log

**Outcome: fully BUILT.** Both walls are solved — a softfp ARMv7 **OpenJDK 11** to host
signal-cli (Wall 1) and the pure-Rust **libsignal_jni + libzkgroup** natives (Wall 2) were
cross-compiled, and `assemble-signal.sh` bundles everything the prpl needs. The one thing left
is **on-device end-to-end testing** (deploy with `deploy-signal.sh`, then watch a real
registration/link) — the JVM footprint on a 1 GB device is the main risk to validate. The three
build steps: `build-jvm.sh` (Wall 1), `build-libsignal.sh` (Wall 2), `build-signal.sh` (the prpl
\+ Java jar); then `assemble-signal.sh` → `deploy-signal.sh`.

## Upstream / vendoring
- Source: **hoehermann/purple-signal** @ `be9adde` (VERSION `0.0.0`), vendored under
  `plugin/purple-signal/` with submodules (`.git` stripped, build artifacts gitignored):
  - `c/submodules/qrcode` — nayuki/QR-Code-generator @ `8cbd1f5`
  - `c/submodules/typedjni` — hoehermann/TypedJNI @ `984df3c`
  - `java/submodules/signal-cli` — hoehermann/signal-cli @ `7c25e06` (v0.6.11-137)
- prpl id: **`prpl-hehoe-signal`** (the `hehoe` infix can't be derived from `type_signal`),
  so an explicit override was added to `imlibpurpleservice` `LibpurpleAdapter.cpp`
  (`getPrplProtocolIdFromServiceName`), alongside the Teams one.

## Architecture (why a JVM is involved at all)
purple-signal is **not** a self-contained C plugin. It is a C++/JNI shim:
```
libpurple → purple-signal (C++/JNI) → embedded JVM → signal-cli (Java) → libsignal_jni (Rust)
```
`typedjni.cpp` calls `JNI_CreateJavaVM` to start a JVM *inside* the messaging process; that
JVM runs signal-cli (Java), whose crypto is delegated to the native Rust libsignal. The JVM
requirement is an artifact of reusing signal-cli, not of Signal itself.

## What was attempted, and what happened

### Stage 1 — Java jar + JNI header (host JDK) → ✅ builds
`build-signal.sh` runs the upstream cmake `purple_signal` target with the host JDK
(OpenJDK 21). It downloads **signal-cli 0.8.0**, compiles the glue + 3 signal-cli source
files, produces **`purple_signal.jar`**, and generates the JNI native header
`de_hehoe_purple_signal_PurpleSignal.h` that `natives.cpp` includes. Note: the cmake
auto-extract of the signal-cli tarball is flaky, so the script extracts it and passes
`SIGNAL_CLI_LIB_DIR` explicitly. From the extracted jars, the backend versions are pinned:
**`signal-client-java 0.2.3`** and **`zkgroup-java 0.7.0`**.

### Stage 2 — full ARM cross-compile of the C++ plugin → ✅ builds
All **18** C++ TUs (`c/CMakeLists.txt` `SRC_LIST`) cross-compile with
`arm-unknown-linux-gnueabi-g++` and link into a valid **ELF32 ARM** `purple-signal.so`
exporting `purple_init_plugin`. `jni.h`/`jni_md.h` are arch-generic enough to compile the
JNI side; the only include the C++ needs from Stage 1 is the generated native header.

### The two RUNTIME walls (neither solvable at build time)

**Wall 1 — needed a modern ARMv7 `libjvm.so` (Java 11+). ✅ NOW SOLVED — built from source.**
The linked `.so` carries exactly **one unresolved dynamic symbol: `JNI_CreateJavaVM`**
(verified with `nm -D -u`), which `g_module_open()` must satisfy from an ARM `libjvm.so`.
None was staged — so we **cross-compiled OpenJDK 11 for the exact device ABI** (see
`build-jvm.sh`):
- **OpenJDK 11.0.32** (`jdk11u`), **Zero** interpreter variant, **headless-only**, built with
  the same `arm-unknown-linux-gnueabi-gcc125` toolchain used for the prpls.
- Output `libjvm.so`: **ELF32 ARM**, exports **`JNI_CreateJavaVM`** + `JNI_GetDefaultJavaVMInitArgs`,
  and — critically — **softfp** (`readelf -A` shows `Tag_ABI_VFP_args` **absent**, CPU arch v7).
  This is why we build from source: Temurin's prebuilt arm32 is **hardfp** and cannot load into
  the softfp imlibpurpletransport process.
- Runtime NEEDED: libdl, libpthread, **libffi.so.8** (WPE staging, already on device), libm,
  libc, ld-linux.so.3 — all satisfiable on-device.
- A full headless JDK image builds (`build-output/openjdk-arm/`, ~453 MB); `jlink` then
  cross-links a **~25 MB minimal JRE** (`build-output/openjdk-arm-jre/`) with just the modules
  signal-cli needs — small enough for the TouchPad.
- Build notes: Zero needs libffi (staging). `--enable-headless-only` still probes X11/cups/
  fontconfig/alsa; since no ARM builds of those exist and signal-cli never uses them, they are
  satisfied with header-only extracts + **ARM stub libs** (X11, libasound) that only need to
  pass the configure/link gates — inert at runtime.

So the JVM to host signal-cli now exists. What remains for a *running* Signal is Wall 2 plus
on-device wiring (deploy the JRE, build libsignal_jni, point purple-signal at both) and testing.

**Wall 2 — the Rust `libsignal_jni` + `libzkgroup`. ✅ SOLVED — cross-compiled.**
signal-cli 0.8.0 needs native Rust libs for non-x86_64 (INSTALL.md: *"No known public build
available"*). Version chain (confirmed from gradle sources): signal-cli 0.8.0 →
`signal-service-java 2.15.3_unofficial_19` (Turasa) → `signal-client-java 0.2.3` (+
`zkgroup-java 0.7.0`). Cross-built by `build-libsignal.sh`:
- **`libsignal_jni.so`** ← `signalapp/libsignal-client` tag `java-0.2.3` (commit `627d7b4`),
  toolchain **nightly-2020-11-09** (pinned; `#![feature(box_patterns)]`). Result: ELF32 ARM,
  softfp, **166** `Java_org_signal_client_internal_Native_*` JNI exports.
- **`libzkgroup.so`** ← `signalapp/zkgroup` tag `v0.7.0`, toolchain **1.41.1**. Result: ELF32
  ARM, softfp, **48** `Java_org_signal_zkgroup_*` JNI exports.
- Both are **100% pure-Rust** crypto (`curve25519-dalek` portable u32 backend, `sha2`/`hmac`/
  `aes`, `aes-gcm-siv` software path) — **no ring/BoringSSL/OpenSSL**, so cross-compiling was
  just the two pinned old toolchains + the ARM cross linker (`CARGO_TARGET_..._LINKER`). The
  earlier "stall" was only the old cargo's slow built-in git index clone — fixed with
  `CARGO_NET_GIT_FETCH_WITH_CLI=true`.
- `assemble-signal.sh` strips them and **swaps them into** `signal-client-java-0.2.3.jar` /
  `zkgroup-java-0.7.0.jar` (replacing the bundled x86_64 resources) so signal-cli's
  `getResourceAsStream` loader extracts the correct arch, and also stages the raw `.so` next to
  the prpl (java.library.path fallback).

## On-device wiring (how the pieces fit)
- `purple-signal.so` is now **linked against libjvm.so** with an **RPATH** to the on-device JRE
  (`…/backend/jre/lib/server` + `/lib`), so `JNI_CreateJavaVM` resolves at `g_module_open()`.
- The prpl builds the JVM classpath from `-Djava.class.path=<plugindir>/purple_signal.jar` + all
  jars in the account's **`signal-cli-lib-dir`** option; the setup app defaults that to
  `…/backend/signal-cli/lib`. `java.library.path` = the plugin dir (natives fallback).
- `deploy-signal.sh` ships the JRE + signal-cli jars as one tarball (robust over novacom) to
  `…/backend/`, and the prpl + jar + two natives into `…/backend/lib/purple-2/`.

## Bottom line
**Signal is fully built** — Wall 1 (softfp ARM OpenJDK 11) and Wall 2 (pure-Rust libsignal_jni +
libzkgroup) are both solved and assembled. The remaining work is **on-device end-to-end testing**:
deploy, add an account, and confirm a real registration/device-link against Signal servers —
watching the JVM startup + memory footprint on the 1 GB device, and noting the plugin is archived
and pinned to signal-cli 0.8.0 (which may need updating if Signal's servers have moved on). The
lighter long-term alternative remains a JVM-free native prpl on Rust `libsignal` (Wall 2 only);
the pure-C `libsignal-protocol-c` is *not* a shortcut (abandoned, rejected by current servers).

## Files
- `build-signal.sh` — Stage 1 (host JDK jar + header) + Stage 2 (ARM C++ .so). Builds, not deployable.
- `deploy-signal.sh` — installs the account template + setup app only; skips the non-loadable .so.
- account template `com.palm.signal` (phone-number), app `com.palm.app.signal` (marked non-functional in-UI).
