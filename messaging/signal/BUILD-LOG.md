# Signal prpl — build log (attempt)

**Outcome: everything BUILDS; it cannot RUN.** Both the Java jar and a full ARM
cross-compile of the C++ plugin succeed, but Signal cannot sign in on the TouchPad
because there is **no ARMv7 JVM for webOS** to host signal-cli. The Rust crypto piece —
the part everyone assumes is the blocker — turns out to be the *tractable* one.

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

**Wall 1 — needs a modern ARMv7 `libjvm.so` (Java 11+) that isn't staged. ← the heavy one.**
The linked `.so` carries exactly **one unresolved dynamic symbol: `JNI_CreateJavaVM`**
(verified with `nm -D -u`). At `g_module_open()` time the loader must satisfy it from an
ARM `libjvm.so`, and there is **no `libjvm.so`/`jni.h` anywhere** in the current ARM sysroot
or staging. This is *not* a fundamental impossibility — a JVM has run on armv7 webOS before
(community homebrew Java: JamVM/cacao, and OpenJDK has an arm32 zero/client port). The
constraint is **suitability**:
- purple-signal embeds a VM in-process via the JNI **invocation API** (`JNI_CreateJavaVM`),
  so it needs a real `libjvm.so`, not a Java-ME/phoneME runtime.
- **signal-cli 0.8.0 requires Java 11+**, so the old Java-6/7-era webOS homebrew builds are
  too old to run it even if present.
- So the actual task is to **cross-compile / stage a modern (Java 11+), invocation-capable
  `libjvm.so` for armv7 / glibc 2.23** (an OpenJDK 11+ arm32 port against the old glibc) —
  a large sub-project, plus its memory footprint on a 1 GB device. Heavy, not walled.

**Wall 2 — the Rust `libsignal_jni` — actually MODERATE, not the blocker.**
signal-cli 0.8.0 needs the native Rust libsignal for non-x86_64 (INSTALL.md: *"No known
public build available"*). Investigated concretely:
- Version chain (confirmed from gradle sources, not guessed): signal-cli 0.8.0 →
  `signal-service-java 2.15.3_unofficial_19` (Turasa) → `signal-client-java 0.2.3` →
  **`signalapp/libsignal-client` tag `java-0.2.3`** (commit `627d7b4`).
- **`rustup target add armv7-unknown-linux-gnueabi` succeeds** — Rust ships an official
  prebuilt `std` for this exact triple/glibc (for both stable and the pinned nightly).
- **Crypto is 100% pure-Rust** — `curve25519-dalek 3.0.0` (portable u32 backend on 32-bit,
  no asm), `sha2`/`hmac`/`aes`, `getrandom 0.1`, Signal's `aes-gcm-siv 0.1`. **No ring, no
  BoringSSL, no OpenSSL** → none of the usual C-crypto cross-compile pain.
- Build wasn't completed here only because the sandbox couldn't fetch the crates.io index
  (an environment limit, not a code blocker). Remaining real tasks: use the pinned
  **`nightly-2020-11-09`** toolchain (required by `#![feature(box_patterns)]`), and confirm
  `aes-gcm-siv`'s software fallback compiles on 32-bit ARM (both AES-NI and aarch64-crypto
  paths are `cfg`-gated off for armv7).
- Verdict: **moderate**, realistic from source. This piece is *not* what makes Signal
  infeasible here.

## Bottom line
Neither piece is a *fundamental* wall — both are large cross-compile sub-projects:
- **Wall 1 (JVM):** stage a modern Java-11+ invocation-capable `libjvm.so` for armv7/glibc-2.23
  (OpenJDK arm32 port). Historically a JVM has run on webOS armv7, just not one new enough for
  signal-cli 0.8.0.
- **Wall 2 (Rust libsignal):** moderate — pure-Rust, official std for the target, needs the
  pinned `nightly-2020-11-09`.

Two realistic routes, both substantial:
1. **Make purple-signal work as-is** — port OpenJDK 11+ to armv7/webOS (Wall 1) *and*
   cross-build libsignal_jni (Wall 2), then ship both plus the signal-cli jars. Heaviest
   runtime (a JVM inside the messaging process on a 1 GB device) and pinned to archived
   signal-cli 0.8.0.
2. **Skip the JVM** — write a JVM-free native prpl directly on the Rust `libsignal` (Wall 2
   only). Lighter and more future-proof, but a from-scratch plugin.

Tracked here as a wired-up placeholder (template + app + backend mapping + this log) for
whichever route is taken. The pure-C `libsignal-protocol-c` is *not* a shortcut: it's
abandoned and rejected by current Signal servers.

## Files
- `build-signal.sh` — Stage 1 (host JDK jar + header) + Stage 2 (ARM C++ .so). Builds, not deployable.
- `deploy-signal.sh` — installs the account template + setup app only; skips the non-loadable .so.
- account template `com.palm.signal` (phone-number), app `com.palm.app.signal` (marked non-functional in-UI).
