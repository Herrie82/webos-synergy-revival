#!/bin/bash
# assemble-signal.sh — collect the full Signal runtime into build-output/signal-runtime/
# from the artifacts produced by the three Signal build steps:
#   build-signal.sh    -> the prpl (purple-signal.so) + purple_signal.jar + signal-cli 0.8.0 jars
#   build-jvm.sh       -> the minimal ARM JRE (build-output/openjdk-arm-jre)
#   build-libsignal.sh -> libsignal_jni.so + libzkgroup.so (armv7)
#
# The two Rust natives are ARM/softfp but the signal-cli jars ship x86_64 copies as jar
# RESOURCES (signal-client-java loads /libsignal_jni.so via getResourceAsStream). We replace
# those resources with the ARM builds so the loader extracts the correct arch; the raw .so
# are also copied next to the prpl (java.library.path = plugin dir, a belt-and-braces fallback).
#
# Layout produced (see deploy-signal.sh for where each goes on-device):
#   signal-runtime/prpl/        purple-signal.so, purple_signal.jar, libsignal_jni.so, libzkgroup.so
#   signal-runtime/signal-cli/  signal-cli 0.8.0 lib/*.jar (with ARM natives swapped in)
#   signal-runtime/jre/         ~25 MB headless ARM JRE
set -e
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SIG=$REPO/messaging/signal/plugin/purple-signal
RUST=${WORK:-/home/herrie/webos/signal-rust}
JRE=$REPO/build-output/openjdk-arm-jre
BUNDLE=$REPO/build-output/signal-runtime
export PATH=/home/herrie/webos/openjdk-port/bootjdk-11/bin:/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/bin:$PATH

rm -rf "$BUNDLE"; mkdir -p "$BUNDLE/prpl" "$BUNDLE/signal-cli/lib" "$BUNDLE/jre"

# 1. prpl + jar (from build-signal.sh)
cp "$SIG/build-arm/purple-signal.so" "$BUNDLE/prpl/"
cp "$(find "$SIG/build-arm" -name purple_signal.jar | head -1)" "$BUNDLE/prpl/"

# 2. signal-cli 0.8.0 jars (downloaded by build-signal.sh Stage 1)
cp "$(find "$SIG/build-arm" -type d -path '*signal-cli-0.8.0/lib' | head -1)"/*.jar "$BUNDLE/signal-cli/lib/"

# 3. Rust natives -> strip, swap into jars, and stage next to prpl
LSJNI=$RUST/libsignal/target/armv7-unknown-linux-gnueabi/release/libsignal_jni.so
ZKG=$RUST/zkgroup/target/armv7-unknown-linux-gnueabi/release/libzkgroup.so
for so in "$LSJNI" "$ZKG"; do cp "$so" "$BUNDLE/prpl/"; arm-unknown-linux-gnueabi-strip --strip-unneeded "$BUNDLE/prpl/$(basename "$so")"; done
( cd "$BUNDLE/prpl" && jar uf "$BUNDLE/signal-cli/lib/signal-client-java-0.2.3.jar" libsignal_jni.so )
( cd "$BUNDLE/prpl" && jar uf "$BUNDLE/signal-cli/lib/zkgroup-java-0.7.0.jar"      libzkgroup.so )

# 4. minimal JRE (from build-jvm.sh)
cp -a "$JRE/." "$BUNDLE/jre/"

echo "=== Signal runtime assembled -> $BUNDLE ($(du -sh "$BUNDLE" | cut -f1)) ==="
ls "$BUNDLE/prpl"
echo "signal-cli jars: $(ls "$BUNDLE/signal-cli/lib" | wc -l)   jre: $(du -sh "$BUNDLE/jre" | cut -f1)"
echo "verify jar natives are ARM:"
for j in signal-client-java-0.2.3.jar:libsignal_jni.so zkgroup-java-0.7.0.jar:libzkgroup.so; do
	unzip -p "$BUNDLE/signal-cli/lib/${j%%:*}" "${j##*:}" > /tmp/_n.so && echo "  ${j%%:*} -> $(file /tmp/_n.so | grep -o 'ELF 32-bit.*ARM')"
done; rm -f /tmp/_n.so
