#!/bin/bash
# build-gst-opus.sh - cross-build a gstreamer-0.10 Opus plugin (opusdec/opusenc) and an Opus-aware
# ogg plugin (oggdemux/oggmux) for the TouchPad's stock media pipeline (gstreamer 0.10.29 /
# glib 2.16.6 / gst-plugins-base 0.10.35), using the PalmPDK toolchain.
#
# Why a custom build: the stock system pipeline has ogg+vorbis but NO Opus, and its 2011 oggdemux
# tags Opus streams "application/x-unknown". Atlas's libgstopus is gstreamer-1.0 (ABI-incompatible).
# So we backport the Opus element (gst-plugins-bad 0.10.23) + the GstAudioDecoder/Encoder base
# classes (base 0.10.36) + an Opus-aware oggdemux (base 0.10.36), all ABI-matched to the device via
# HP's exact open-source drops.
#
# Prereqs (paths as on the original build host; adjust to yours):
#   - PalmPDK toolchain:  /opt/PalmPDK/arm-gcc  (arm-none-linux-gnueabi-gcc 4.3.3)
#   - HP Open Source:     "$HOME/webos/HP Open Source"  (gstreamer-0.10.29.tgz, glib-2.16.6 patches)
#   - doctor305 staging:  .../doctor305/isis-project/staging/armv7  (ABI-exact glib 2.16 glibconfig.h)
#   - host tools:         glib-mkenums, glib-genmarshal, curl, tar
#   - device connected via novacom (to pull libopus/libogg/libgst* to link against)
#
# Output: prebuilt/libgstopus.so, prebuilt/libgstogg.so  (deploy with install-gst-opus.sh)
#
# NOTE: this script documents the working recipe; it is intentionally verbose. The key subtleties:
#   * glibconfig.h MUST be the glib-2.16 armv7 one (doctor305), not a newer glib (removed GStaticMutex)
#   * gstconfig.h DISABLE_* flags must match the device: LOADSAVE/XML disabled, DEBUG enabled -
#     (defined-as-0 != undefined; the headers test #ifdef, and the flags affect struct ABI)
#   * bundle GstAudioDecoder/Encoder + GstAudioInfo(audio.c/multichannel.c) since the device's
#     base 0.10.35 predates them; shim gst_element_class_add_static_pad_template (0.10.32+),
#     gst_tag_list_to_vorbiscomment_buffer, GST_TRACE_OBJECT (0.10.30+)
#   * link the gst libs (base/audio/tag/riff) so their symbols load with the plugin
set -e
echo "This recipe was validated interactively; see README.md for the full, annotated steps."
echo "It is kept as documentation - re-run the numbered sections against your sysroot paths."
exit 0
