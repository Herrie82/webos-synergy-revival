#!/bin/bash
# build-libsignal.sh — cross-compile the Rust native libs that signal-cli 0.8.0 needs on
# ARM (Wall 2 of the Signal port): libsignal_jni.so + libzkgroup.so for armv7 / glibc 2.23.
# Together with the OpenJDK 11 from build-jvm.sh (Wall 1), these complete the Signal runtime.
#
# Version chain (confirmed from gradle sources): signal-cli 0.8.0 -> signal-service-java
# 2.15.3_unofficial_19 -> signal-client-java 0.2.3 (+ zkgroup-java 0.7.0). So:
#   - libsignal_jni  <- signalapp/libsignal-client, tag java-0.2.3  (pins nightly-2020-11-09)
#   - libzkgroup     <- signalapp/zkgroup,          tag v0.7.0      (pins rust 1.41.1)
# Both are PURE-RUST crypto (no ring/BoringSSL), so they cross-compile cleanly; the only
# fuss is the two pinned old toolchains and pointing cargo at the ARM cross linker.
#
# Output natives are ARM/softfp (Tag_ABI_VFP_args absent) and are swapped INTO the two jars
# (replacing the bundled x86_64 resource) by assemble-signal.sh so signal-cli's resource
# loader extracts the correct arch.
set -e

WORK=${WORK:-/home/herrie/webos/signal-rust}
TC=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125
export PATH=$TC/bin:$PATH
export CARGO_NET_GIT_FETCH_WITH_CLI=true   # old cargo's built-in git index clone is painfully slow
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER=arm-unknown-linux-gnueabi-gcc
export CC_armv7_unknown_linux_gnueabi=arm-unknown-linux-gnueabi-gcc
export AR_armv7_unknown_linux_gnueabi=arm-unknown-linux-gnueabi-ar
export CFLAGS_armv7_unknown_linux_gnueabi="-march=armv7-a -mfpu=neon -mfloat-abi=softfp"
TARGET=armv7-unknown-linux-gnueabi
mkdir -p "$WORK"

command -v rustup >/dev/null || { echo "rustup required (https://rustup.rs)"; exit 1; }
rustup toolchain install nightly-2020-11-09 --profile minimal 2>/dev/null || true
rustup toolchain install 1.41.1 --profile minimal 2>/dev/null || true
rustup target add --toolchain nightly-2020-11-09 $TARGET
rustup target add --toolchain 1.41.1 $TARGET

echo "=== libsignal_jni (libsignal-client java-0.2.3) ==="
[ -d "$WORK/libsignal" ] || git clone --depth 1 --branch java-0.2.3 https://github.com/signalapp/libsignal-client.git "$WORK/libsignal"
( cd "$WORK/libsignal" && rustup run nightly-2020-11-09 cargo build --release --target $TARGET -p libsignal-jni )
LIBSIGNAL=$WORK/libsignal/target/$TARGET/release/libsignal_jni.so

echo "=== libzkgroup (zkgroup v0.7.0) ==="
[ -d "$WORK/zkgroup" ] || git clone --depth 1 --branch v0.7.0 https://github.com/signalapp/zkgroup.git "$WORK/zkgroup"
( cd "$WORK/zkgroup/rust" && rustup run 1.41.1 cargo build --release --target $TARGET )
LIBZKGROUP=$WORK/zkgroup/target/$TARGET/release/libzkgroup.so

echo ""
echo "=== Result ==="
for so in "$LIBSIGNAL" "$LIBZKGROUP"; do
	arm-unknown-linux-gnueabi-strip --strip-unneeded "$so" 2>/dev/null || true
	echo "$so"
	arm-unknown-linux-gnueabi-readelf -h "$so" | grep -E "Machine|Class"
	echo "  softfp (0 = softfp): $(arm-unknown-linux-gnueabi-readelf -A "$so" | grep -c Tag_ABI_VFP_args)"
	echo "  JNI exports: $(arm-unknown-linux-gnueabi-nm -D "$so" | grep -c ' T Java_')"
done
echo ""
echo "Next: assemble-signal.sh bundles these + the JRE + signal-cli jars + purple_signal.jar + the prpl."
