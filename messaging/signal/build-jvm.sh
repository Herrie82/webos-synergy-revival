#!/bin/bash
# build-jvm.sh — cross-compile OpenJDK 11 (Zero, headless) for webOS 3.0.5
# ARMv7 **softfp** / glibc 2.23, to provide the libjvm.so that purple-signal
# needs (Wall 1: JNI_CreateJavaVM). See BUILD-LOG.md.
#
# This produces a genuinely softfp ARM libjvm.so — verified with
#   readelf -A libjvm.so   ->  Tag_ABI_VFP_args ABSENT (softfp), Tag_CPU_arch v7
# so it loads into the softfp imlibpurpletransport process (Temurin's hardfp
# arm32 builds do NOT — that is why we build from source).
#
# Heavy build (~1 GB source + multi-GB build tree); everything lives OUTSIDE the
# repo under $PORT (gitignored by nature). The final image is copied to
# build-output/openjdk-arm/ for staging by deploy-signal.sh.
set -e

PORT=${PORT:-/home/herrie/webos/openjdk-port}
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
TC=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125
SYSROOT=$TC/arm-unknown-linux-gnueabi/sysroot
STAGING=/home/herrie/webos/wpe/staging-glibc-252        # ARM freetype + libffi.so.8 (device has these via WPE)
JDK_TAG=${JDK_TAG:-jdk-11.0.32+8}
BOOT_URL="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.25%2B9/OpenJDK11U-jdk_x64_linux_hotspot_11.0.25_9.tar.gz"
CONF=linux-arm-normal-zero-release

mkdir -p "$PORT"; cd "$PORT"
export PATH=$TC/bin:$PATH

# --- 1. boot JDK 11 (host x64) — jdk11u must be bootstrapped by an 11-era JDK ---
if [ ! -x bootjdk-11/bin/javac ]; then
	curl -fL --retry 3 -o bootjdk11.tgz "$BOOT_URL"
	mkdir -p bootjdk-11 && tar -C bootjdk-11 --strip-components=1 -xzf bootjdk11.tgz && rm -f bootjdk11.tgz
fi

# --- 2. jdk11u source ---
[ -d jdk11u ] || git clone --depth 1 --branch "$JDK_TAG" https://github.com/openjdk/jdk11u.git

# --- 3. host-side build deps extracted WITHOUT root (headers only; cross gcc can't see /usr/include) ---
#   cups + all X11 extension headers. Zero+headless still makes configure PROBE X11/cups/fontconfig.
mkdir -p deps && cd deps
if [ ! -f cups/usr/include/cups/raster.h ]; then
	# cups.h + ppd.h from libcups2-dev, raster.h (ppd.h includes it) from libcupsimage2-dev
	apt-get download libcups2-dev libcupsimage2-dev >/dev/null 2>&1
	for d in libcups2-dev_*.deb libcupsimage2-dev_*.deb; do dpkg-deb -x "$d" cups; done
fi
# fontconfig + alsa headers must go in CLEAN prefixes (NOT /usr/include): pointing the cross
# compiler at host /usr/include drags in host glibc stdlib.h (_Float128) and breaks java.desktop.
if [ ! -f fcinc/root/usr/include/fontconfig/fontconfig.h ]; then
	mkdir -p fcinc && cd fcinc && apt-get download libfontconfig-dev libfontconfig1-dev >/dev/null 2>&1
	for d in *.deb; do dpkg-deb -x "$d" root; done; cd ..
fi
if [ ! -f alsainc/root/usr/include/alsa/asoundlib.h ]; then
	mkdir -p alsainc && cd alsainc && apt-get download libasound2-dev >/dev/null 2>&1
	for d in *.deb; do dpkg-deb -x "$d" root; done; cd ..
fi
# ARM STUB libasound: java.desktop's libjsound links -lasound, but there is no ARM libasound
# (and signal-cli never uses javax.sound). A complete no-op stub (symbol list mirrored from the
# host libasound) lets libjsound link; it's inert on-device.
if [ ! -f alsastub/libasound.so ]; then
	mkdir -p alsastub
	nm -D --defined-only "$(ls /usr/lib/x86_64-linux-gnu/libasound.so.2* | head -1)" \
		| awk '$2 ~ /[TWi]/ {print $3}' | sed 's/@.*//' | grep '^snd_' | sort -u \
		| awk '{print "int "$1"(void){return 0;}"}' > alsastub/stub.c
	arm-unknown-linux-gnueabi-gcc -shared -fPIC -o alsastub/libasound.so alsastub/stub.c -Wl,-soname,libasound.so.2
fi
if [ ! -f xinc/root/usr/include/X11/extensions/XTest.h ]; then
	mkdir -p xinc && cd xinc
	for p in libx11-dev libxext-dev libxrender-dev libxrandr-dev libxtst-dev libxt-dev \
	         libxi-dev libxinerama-dev x11proto-dev xorg-sgml-doctools libxau-dev libxdmcp-dev; do
		apt-get download "$p" >/dev/null 2>&1 || true
	done
	mkdir -p root; for d in *.deb; do dpkg-deb -x "$d" root; done
	cd ..
fi
# --- 4. ARM X11 STUB libs: no ARM X11 exists; headless never uses it at runtime, but configure
#        link-tests it. Empty-ish stubs that define the probed symbols satisfy the gate. ---
if [ ! -f x11stub/lib/libX11.so ]; then
	mkdir -p x11stub/lib
	cat > x11stub/stub.c <<'C'
int XrmInitialize(void){return 0;} void *XOpenDisplay(const char*d){(void)d;return 0;}
int XextAddDisplay(void){return 0;} int XextFindDisplay(void){return 0;} int XextRemoveDisplay(void){return 0;}
void *XextCreateExtension(void){return 0;} int XrenderQueryExtension(void){return 0;} int XRRQueryExtension(void){return 0;}
int XTestFakeKeyEvent(void){return 0;} int XineramaQueryScreens(void){return 0;} int XtToolkitInitialize(void){return 0;}
int IceConnectionNumber(void){return 0;}
C
	for L in X11 Xext Xrender Xrandr Xtst Xt Xi Xinerama; do
		arm-unknown-linux-gnueabi-gcc -shared -fPIC -o x11stub/lib/lib$L.so x11stub/stub.c -Wl,-soname,lib$L.so.6
	done
fi
cd "$PORT"

# --- 5. configure the cross-build ---
cd jdk11u
bash configure \
	--openjdk-target=arm-unknown-linux-gnueabi \
	--with-sysroot="$SYSROOT" \
	--with-boot-jdk="$PORT/bootjdk-11" \
	--with-jvm-variants=zero \
	--enable-headless-only \
	--disable-warnings-as-errors \
	--with-zlib=bundled --with-libjpeg=bundled --with-giflib=bundled \
	--with-libpng=bundled --with-lcms=bundled \
	--with-freetype-include="$STAGING/include/freetype2" --with-freetype-lib="$STAGING/lib" \
	--with-libffi-include="$STAGING/include" --with-libffi-lib="$STAGING/lib" \
	--with-cups-include="$PORT/deps/cups/usr/include" \
	--with-fontconfig-include="$PORT/deps/fcinc/root/usr/include" \
	--with-alsa-include="$PORT/deps/alsainc/root/usr/include" --with-alsa-lib="$PORT/deps/alsastub" \
	--x-includes="$PORT/deps/xinc/root/usr/include" --x-libraries="$PORT/deps/x11stub/lib" \
	--with-extra-cflags="-DARM" --with-extra-cxxflags="-DARM" \
	BUILD_CC=/usr/bin/gcc BUILD_CXX=/usr/bin/g++

# --- 6. build ---
#   'make hotspot' -> just libjvm.so (Wall 1 proof). 'make images' -> full headless JRE/JDK.
TARGET=${1:-images}
make "$TARGET" CONF="$CONF"

JDKIMG=$PORT/jdk11u/build/$CONF/images/jdk
echo ""
echo "=== Result ==="
LIBJVM=$(find "$PORT/jdk11u/build/$CONF" -name libjvm.so | head -1)
arm-unknown-linux-gnueabi-readelf -h "$LIBJVM" | grep -E "Machine|Class"
echo "JNI_CreateJavaVM: $(arm-unknown-linux-gnueabi-nm -D "$LIBJVM" | grep -c JNI_CreateJavaVM)"
echo "softfp (Tag_ABI_VFP_args absent = OK): $(arm-unknown-linux-gnueabi-readelf -A "$LIBJVM" | grep -c Tag_ABI_VFP_args) (0 = softfp)"
if [ -d "$JDKIMG" ]; then
	mkdir -p "$REPO/build-output/openjdk-arm"
	cp -a "$JDKIMG/." "$REPO/build-output/openjdk-arm/"
	echo "full JDK image staged -> build-output/openjdk-arm/ ($(du -sh "$REPO/build-output/openjdk-arm" | cut -f1))"

	# jlink a MINIMAL headless JRE for signal-cli (~25 MB vs ~450 MB). The host boot JDK's
	# jlink cross-links the ARM jmods into an ARM runtime. Module set covers signal-cli's
	# needs (crypto, naming, http, sql for its local store, logging, management); widen if
	# 'jdeps' on the actual signal-cli jars shows more.
	MINJRE=$REPO/build-output/openjdk-arm-jre
	rm -rf "$MINJRE"
	"$PORT/bootjdk-11/bin/jlink" --module-path "$JDKIMG/jmods" \
		--add-modules java.base,java.logging,java.naming,java.sql,java.xml,java.management,jdk.crypto.ec,jdk.crypto.cryptoki,jdk.unsupported,java.net.http,java.security.jgss,java.security.sasl,jdk.net \
		--no-header-files --no-man-pages --strip-debug --compress=2 --output "$MINJRE"
	echo "minimal JRE staged -> build-output/openjdk-arm-jre/ ($(du -sh "$MINJRE" | cut -f1))"
fi
