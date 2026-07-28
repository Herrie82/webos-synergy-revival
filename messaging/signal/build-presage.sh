#!/bin/bash
# Cross-compile the purple-presage Rust backend (libpurple_presage_backend.a) for webOS 3.0.5
# ARMv7 **softfp** / glibc 2.23. This is the JVM-free Signal path (native Rust `presage`), replacing
# the heavy purple-signal (JVM + signal-cli). The C prpl (presage.so) links this .a — built separately.
#
# Notes on the tree (confirmed via cargo tree):
#   - TLS = rustls + ring (no OpenSSL/native-tls) -> no OpenSSL cross-libs needed.
#   - sha2-asm is NOT built for arm32 (sha2's asm feature is x86/x86_64/aarch64-only) -> no patch needed.
#   - bindgen is a manual one-time step; src/rust/src/bridge_structs.rs is checked in.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
RUST=$REPO/messaging/signal/plugin/purple-presage/src/rust
TC=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125
SR=$TC/arm-unknown-linux-gnueabi/sysroot
TARGET=armv7-unknown-linux-gnueabi
P=arm-unknown-linux-gnueabi-

export PATH="$TC/bin:$PATH"
export CARGO_NET_GIT_FETCH_WITH_CLI=true

# libsignal-service-rs + spqr generate code from .proto via prost-build -> need a modern HOST protoc
# (the .proto use proto3 `optional`, which needs protoc >= 3.15; the Qt-bundled 3.0.0 is too old).
# Prebuilt protoc 27.2 stashed under build-output/host-tools (gitignored).
export PROTOC="$REPO/build-output/host-tools/protoc"

# presage-store-sqlite pulls whisperfish's rusqlite fork, which compiles SQLCipher (encrypted
# SQLite, -DSQLITE_HAS_CODEC) -> needs OpenSSL crypto headers to build and libcrypto at link.
# This SQLCipher uses the OpenSSL 3.0 provider API (EVP_MAC / OSSL_PARAM), so it must build
# against 3.0 headers; libcrypto.so.3 (arm) then gets deployed to the device alongside the plugin.
OSSL=/home/herrie/webos/wpe/staging-glibc-252
OSSL_INC="$OSSL/include"
OSSL_LIB="$OSSL/lib"
export OPENSSL_INCLUDE_DIR="$OSSL_INC"
export OPENSSL_LIB_DIR="$OSSL_LIB"
export OPENSSL_DIR="$OSSL"

# Rust cross env (softfp, glibc-2.23 sysroot). Drives the cc-crate C builds in ring/libsqlite3-sys/etc.
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER=${P}gcc
export CC_armv7_unknown_linux_gnueabi=${P}gcc
export CXX_armv7_unknown_linux_gnueabi=${P}g++
export AR_armv7_unknown_linux_gnueabi=${P}ar
export CFLAGS_armv7_unknown_linux_gnueabi="-march=armv7-a -mfloat-abi=soft --sysroot=$SR -I$OSSL_INC"
export CXXFLAGS_armv7_unknown_linux_gnueabi="-march=armv7-a -mfloat-abi=soft --sysroot=$SR -I$OSSL_INC"

# boring-sys (BoringSSL, only pulled in when presage's `cdsi` feature is on for non-contact Signal
# discovery): its bundled cmake/armv7-linux.cmake sets no compiler, so cmake falls back to the host
# /usr/bin/cc and dies on -mfloat-abi=soft. Hand cmake our cross toolchain instead. TARGET_-prefixed
# so it's honored by both boring-sys and the cmake crate, and only for the ARM target (not host).
export TARGET_CMAKE_TOOLCHAIN_FILE="$REPO/messaging/signal/boring-arm-toolchain.cmake"
# BoringSSL's build generates sources with Go and configures with cmake; make sure both are found.
export PATH="/home/herrie/webos/gotool/go125/bin:$REPO/build-output/host-tools:$PATH"

cd "$RUST"
echo "=== STAGE 1: cargo build Rust backend staticlib --target $TARGET (387 crates, be patient) ==="
cargo build --release --target "$TARGET" "$@"
BACKEND="$RUST/target/$TARGET/release/libpurple_presage_backend.a"
ls -la "$BACKEND"

# --- STAGE 2: build the C prpl (libpresage.so) and link the Rust staticlib ---------------------
echo "=== STAGE 2: compile + link C prpl (libpresage.so) ==="
C=$REPO/messaging/signal/plugin/purple-presage/src/c
PURPLE=$REPO/messaging/libpurple
BUILD=$REPO/messaging/signal/plugin/purple-presage/build-arm
mkdir -p "$BUILD/obj"

# luna-service2 for the com.palm.signal.call LS2 service (call.c). Link against the device stub .so;
# the real /usr/lib/liblunaservice.so resolves at load inside imlibpurpletransport.
# lunaservice.h itself does #include <luna-service2/...>, so BOTH include/public and its luna-service2/
# subdir must be on the path (matches the Telegram build).
LUNA_INC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/luna-service2/include/public
PMLOG_INC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/woce-build-support/staging/arm-none-linux-gnueabi/include/PmLogLib/IncsPublic
LSSTUB=$REPO/build-output/imtransport/lib/liblunaservice.so
export PKG_CONFIG_PATH="$OSSL/lib/pkgconfig:$OSSL/../staging-glibc-252/lib/pkgconfig"
GLIB=/home/herrie/webos/wpe/staging-glibc-252
export PKG_CONFIG_PATH="$GLIB/lib/pkgconfig"
GLIB_CFLAGS=$(pkg-config --cflags glib-2.0 gobject-2.0)

# NB: gdk-pixbuf deliberately NOT on the include path -> pixbuf.c uses its jpeg/png fallback.
CFLAGS="-fPIC -O2 -march=armv7-a -mfloat-abi=soft --sysroot=$SR -DPURPLE_PLUGINS
  -DPLUGIN_VERSION=\"0.0.0-webos\" -I$C -I$PURPLE/include/libpurple -I$PURPLE/include $GLIB_CFLAGS
  -I$LUNA_INC -I$LUNA_INC/luna-service2 -I$PMLOG_INC"

SRCS="init.c bridge.c connection.c qrcode.c receive_text.c send_text.c blist.c status.c groups.c \
      receive_attachment.c send_file.c profile.c options.c attachment_common.c pixbuf.c call.c"
OBJS=""
for s in $SRCS; do
  o="$BUILD/obj/${s%.c}.o"
  echo "  CC $s"
  ${P}gcc $CFLAGS -c "$C/$s" -o "$o"
  OBJS="$OBJS $o"
done

echo "=== Linking libpresage.so ==="
# objects -> rust staticlib -> its native deps (crypto for sqlcipher; stdc++/pthread/dl/m/rt/util/gcc_s
# from `cargo rustc -- --print native-static-libs`). rustls/ring bring their own crypto (no -lssl).
${P}g++ -shared -fPIC -march=armv7-a -mfloat-abi=soft --sysroot=$SR -Wl,-soname,libpresage.so \
  $OBJS \
  -Wl,--start-group "$BACKEND" -L"$PURPLE/lib" -lpurple -L"$OSSL/lib" -lcrypto -Wl,--end-group \
  "$LSSTUB" \
  -lstdc++ -lpthread -ldl -lm -lrt -lutil -lgcc_s \
  -o "$BUILD/libpresage.so"
echo "=== Result ==="
${P}readelf -h "$BUILD/libpresage.so" | grep -E "Machine|Type"
echo "prpl id: $(${P}nm -D "$BUILD/libpresage.so" | grep -c purple_init_plugin) (1=ok)"
echo "undefined non-glibc/purple symbols (should be empty/resolvable at load):"
${P}nm -D "$BUILD/libpresage.so" | grep " U " | grep -ivE "GLIBC|purple_|_ITM|__gmon|__cxa|gobject|g_|json" | head
ls -la "$BUILD/libpresage.so"
