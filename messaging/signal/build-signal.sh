#!/bin/bash
# build-signal.sh — cross-compile the Signal prpl (hoehermann/purple-signal
# -> purple-signal.so) for webOS 3.0.5 ARM (HP TouchPad).
#
# ============================================================================
#  STATUS: WORKS ON DEVICE. Both "hard walls" that once blocked this are solved:
# ----------------------------------------------------------------------------
#  purple-signal is a C++/JNI shim that embeds a Java VM in-process
#  (JNI_CreateJavaVM) and drives signal-cli (Java); signal-cli's crypto is the
#  Rust libsignal (signal-client-java 0.2.3 -> libsignal_jni, + zkgroup 0.7.0).
#    1. ARMv7 JVM: built as OpenJDK 11 Zero, softfp (build-jvm.sh). The in-process
#       JVM SIGSEGVs under the Teams-port loader /lib/ld-teams.so.3 but runs under
#       the wpe-glibc loader, so imlibpurpletransport is linked against that loader
#       (see imlibpurpleservice/build.sh --dynamic-linker + imwrap.sh).
#    2. ARMv7 libsignal_jni + zkgroup: cross-built for armv7/glibc-2.23
#       (build-libsignal.sh) and swapped into the signal-cli jars as resources.
#  IMPORTANT: link ALL of c/ (incl. c/handler/*, c/purplesignal/*) — a partial
#  link leaves PurpleSignal::close() undefined and the plugin will not load.
# ============================================================================
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/signal/plugin/purple-signal
C=$SRC/c
BUILD=$SRC/build-arm                                      # build dir (gitignored)
PURPLE=$REPO/messaging/libpurple                          # prebuilt libpurple 2.14 staging (this repo)
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252     # glib/openssl/zlib staging (external dep)
HOST_JDK=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64} # host JDK: JNI headers + jar/native-header build

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true
: "${CXX:=arm-unknown-linux-gnueabi-g++}"
export JAVA_HOME="$HOST_JDK"

mkdir -p "$BUILD/jni"
cp "$HOST_JDK/include/jni.h" "$HOST_JDK/include/linux/jni_md.h" "$BUILD/jni/"

# ---------------------------------------------------------------------------
# STAGE 1 (host JDK): build purple_signal.jar + generate the JNI native header
# (de_hehoe_purple_signal_PurpleSignal.h) that natives.cpp #includes. The upstream
# cmake downloads signal-cli 0.8.0 the first time (needs network); we then point
# SIGNAL_CLI_LIB_DIR at the extracted jars (the cmake auto-extract path is flaky).
# PKG_CONFIG_PATH must expose purple.pc so the project (which also declares the c/
# target) configures; the Java target itself does not use libpurple.
# ---------------------------------------------------------------------------
JDIR=$BUILD/java
mkdir -p "$JDIR"
CLI_TGZ=$JDIR/signal-cli-0.8.0.tar.gz
CLI_LIB=$JDIR/signal-cli-0.8.0/lib
if [ ! -f "$CLI_LIB/signal-cli-0.8.0.jar" ]; then
	[ -f "$CLI_TGZ" ] || curl -L -o "$CLI_TGZ" \
		https://github.com/AsamK/signal-cli/releases/download/v0.8.0/signal-cli-0.8.0.tar.gz
	tar -C "$JDIR" -xzf "$CLI_TGZ"
fi
export PKG_CONFIG_PATH=$PURPLE/lib/pkgconfig:$GLIB_STAGING/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
echo "=== STAGE 1: Java jar + JNI native header (host JDK) ==="
cmake -S "$SRC" -B "$JDIR/cmake" -DCMAKE_BUILD_TYPE=Release -DSIGNAL_CLI_LIB_DIR="$CLI_LIB" >/dev/null
cmake --build "$JDIR/cmake" --target purple_signal
HDR=$(dirname "$(find "$JDIR/cmake" -name de_hehoe_purple_signal_PurpleSignal.h | head -1)")
JAR=$(find "$JDIR/cmake" -name purple_signal.jar | head -1)
echo "  native header: $HDR"
echo "  jar:           $JAR"

# ---------------------------------------------------------------------------
# STAGE 2 (ARM cross): compile the full c/CMakeLists SRC_LIST for ARM and link.
# Link against the cross-built OpenJDK's libjvm.so (build-jvm.sh) so JNI_CreateJavaVM
# resolves; bake an rpath to the JRE's on-device location so the messaging process can
# find libjvm.so + its deps at g_module_open() time.
# ---------------------------------------------------------------------------
JRE=${JRE:-$REPO/build-output/openjdk-arm-jre}                 # cross-built ARM JRE (build-jvm.sh)
ONDEVICE_JRE=${ONDEVICE_JRE:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/jre}
PC=$(pkg-config --cflags purple glib-2.0)
PL=$(pkg-config --libs purple glib-2.0)
FLAGS=($CXXFLAGS $CPPFLAGS -std=c++17 -fPIC -DPURPLE_PLUGINS
	-DGLIB_DISABLE_DEPRECATION_WARNINGS -Wno-write-strings -Wno-parentheses
	-I"$C" -I"$C/submodules/typedjni" -I"$C/submodules/qrcode/cpp" -I"$BUILD/jni" -I"$HDR" -I"$PURPLE/include" $PC
	-DSIGNAL_PLUGIN_VERSION='"0.0.0"' -DOWN_FILE_NAME='"purple-signal.so"' -DSIGNAL_CLI_JAR='"signal-cli-0.8.0.jar"')
SRCS=(c/libsignal.cpp c/environment.cpp c/connection.cpp c/buddies.cpp c/natives.cpp
	c/handler/account.cpp c/handler/async.cpp c/handler/message.cpp c/handler/attachment.cpp c/handler/contact.cpp
	c/purplesignal/account.cpp c/purplesignal/construction.cpp c/purplesignal/message.cpp
	c/purplesignal/attachment.cpp c/purplesignal/utils.cpp c/purplesignal/error.cpp
	c/submodules/typedjni/typedjni.cpp c/submodules/qrcode/cpp/QrCode.cpp)

echo "=== STAGE 2: cross-compile the C++ plugin for ARM ==="
OBJS=()
for s in "${SRCS[@]}"; do
	o="$BUILD/$(echo "$s" | tr '/' '_').o"
	echo "  CXX $s"
	$CXX "${FLAGS[@]}" -c "$SRC/$s" -o "$o"
	OBJS+=("$o")
done
echo "=== Linking purple-signal.so against libjvm (rpath -> on-device JRE) ==="
$CXX -shared -fPIC $LDFLAGS -Wl,-soname,purple-signal.so "${OBJS[@]}" $PL \
	-L"$JRE/lib/server" -ljvm \
	-Wl,-rpath-link,"$JRE/lib/server" -Wl,-rpath-link,"$JRE/lib" \
	-Wl,-rpath,"$ONDEVICE_JRE/lib/server" -Wl,-rpath,"$ONDEVICE_JRE/lib" \
	-o "$BUILD/purple-signal.so"

echo ""
echo "=== Result ==="
arm-unknown-linux-gnueabi-readelf -h "$BUILD/purple-signal.so" | grep -E "Machine|Type"
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D "$BUILD/purple-signal.so" | grep -c purple_init_plugin)"
echo "NEEDED libjvm: $(arm-unknown-linux-gnueabi-readelf -d "$BUILD/purple-signal.so" | grep -c 'libjvm.so')  (1 = JNI_CreateJavaVM will resolve from the JRE)"
echo "rpath: $(arm-unknown-linux-gnueabi-readelf -d "$BUILD/purple-signal.so" | grep -oE 'RUNPATH.*|RPATH.*' | head -1)"
echo ""
# Verify the full link: PurpleSignal::close() must be DEFINED (T), not undefined (U). A partial
# link (top-level c/*.cpp only) leaves it undefined and the plugin fails to load on device.
echo "PurpleSignal::close(): $(arm-unknown-linux-gnueabi-nm -C "$BUILD/purple-signal.so" | grep -E 'T PurpleSignal::close' | head -1 || echo 'MISSING -> partial link!')"
echo "== Built. Deploy purple-signal.so via deploy-signal.sh (needs the wpe-glibc-linked transport). =="
