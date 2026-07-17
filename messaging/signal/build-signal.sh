#!/bin/bash
# build-signal.sh — ATTEMPT to cross-compile the Signal prpl (hoehermann/purple-signal
# -> purple-signal.so) for webOS 3.0.5 ARM (HP TouchPad).
#
# ============================================================================
#  !!  THIS PRODUCES A .so THAT CANNOT RUN ON THE DEVICE  !!
# ----------------------------------------------------------------------------
#  purple-signal is a C++/JNI shim that embeds a Java VM in-process
#  (JNI_CreateJavaVM) and drives signal-cli (Java); signal-cli's crypto is the
#  Rust libsignal (signal-client-java 0.2.3 -> libsignal_jni, + zkgroup 0.7.0).
#  BOTH stages below build fine cross-arch, but there are two hard RUNTIME walls
#  on webOS ARMv7 (glibc 2.23), neither solvable at build time:
#    1. NO ARMv7 JVM for webOS. The compiled .so carries an unresolved
#       JNI_CreateJavaVM that g_module_open() must satisfy from an ARM libjvm.so
#       — none exists. The plugin will not load.
#    2. NO ARMv7 libsignal_jni. signal-cli needs the native Rust libsignal
#       (v0.2.3) + zkgroup (0.7.0) built for armv7/old-glibc; upstream states
#       "No known public build available" and a from-source cross-build is
#       impractical (see BUILD-LOG.md).
#  This script exists to (a) show exactly how far a cross-compile gets — both the
#  Java jar and the full ARM C++ .so DO build — and (b) keep the plugin wired
#  into the tree for the day a native (JVM-free) Signal path exists.
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
# The unresolved JNI_CreateJavaVM is EXPECTED (shared objects tolerate it at link).
# ---------------------------------------------------------------------------
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
echo "=== Linking purple-signal.so (undefined JNI_CreateJavaVM is expected) ==="
$CXX -shared -fPIC $LDFLAGS -Wl,-soname,purple-signal.so "${OBJS[@]}" $PL -o "$BUILD/purple-signal.so"

echo ""
echo "=== Result ==="
arm-unknown-linux-gnueabi-readelf -h "$BUILD/purple-signal.so" | grep -E "Machine|Type"
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D "$BUILD/purple-signal.so" | grep -c purple_init_plugin)"
echo "UNRESOLVED (runtime wall): $(arm-unknown-linux-gnueabi-nm -D -u "$BUILD/purple-signal.so" | grep -c JNI_CreateJavaVM) x JNI_CreateJavaVM  <- needs an ARM libjvm.so on device (none exists)"
echo ""
echo "!! Built (jar + ARM .so), but NOT deployable: no ARMv7 JVM and no ARMv7 libsignal_jni. See BUILD-LOG.md. !!"
