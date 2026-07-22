# gst-video-codecs — WebM (VP8/VP9), Matroska & Speex for the stock media pipeline

Backports **VP8 + VP9 video**, the **Matroska/WebM demuxer**, and **Speex audio** into the
TouchPad's **gstreamer-0.10** pipeline, so the stock Video player (and Messaging attachment
playback) handle **WebM** video — Telegram/Discord clips and video stickers — natively. Companion
to `../gst-opus-codec` (Opus). No Atlas, no transcode.

## The gaps this fills

The stock 2011 pipeline (`gst-ffmpeg`/`libavcodec.52`) decodes H.264/MPEG-4/H.263 + AAC/MP3/AMR,
but had **no VP8, no VP9, no Matroska demuxer** (so WebM couldn't even be opened), and no Speex.

## What we ship

| File | Provides |
|------|----------|
| `prebuilt/libgstvpx.so`      | `vp8dec` + `vp9dec` (libvpx 1.3.0 **static-linked** in) |
| `prebuilt/libgstmatroska.so` | `matroskademux` + `matroskamux`, **patched to recognise VP9** (`V_VP9`) |
| `prebuilt/libgstspeex.so`    | `speexdec` (links the on-device `libspeex`) |

Install: `./install-gst-video-codecs.sh`. Verified on device:

```
gst-launch-0.10 filesrc location=<x>.webm ! matroskademux ! vp9dec ! fakesink   # PLAYING -> EOS
```

VP9 confirmed **actually decoding**: `vp9dec` src caps `video/x-raw-yuv I420 640x360`, emitting real
345600-byte (640×360×1.5) frames; `decodebin2`/`uridecodebin` auto-plug it.

## How it was built

Cross-built with the **PalmPDK** toolchain against HP's ABI-exact gstreamer-0.10.29 / glib-2.16.6 /
base-0.10.35 (same setup as `../gst-opus-codec`).

- **libvpx 1.3.0** — configured `--target=generic-gnu --extra-cflags=-march=armv7-a` (PalmPDK gcc
  4.3.3 rejects libvpx's `armv7-linux-gcc` target's `-mcpu=cortex-a8`). Pure-C (no NEON asm); decode
  of typical messaging clips/stickers is fine. Static `.a` linked into the plugin.
- **vp8dec** from `gst-plugins-bad-0.10.23/ext/vp8`, bundling `GstBaseVideoDecoder` (bad-0.10.23
  gst-libs). Compile with `-DHAVE_VP8_DECODER` (the whole element is `#ifdef`'d on it).
- **vp9dec** — `src/gstvp9dec.{c,h}`, derived from vp8dec by targeted identifier replacement
  (`vpx_codec_vp8_dx`→`vp9_dx`, `video/x-vp8`→`video/x-vp9`, `GstVP8Dec`→`GstVP9Dec`, …) while
  **preserving** the libvpx `VP8_*` post-processing constants (post-proc defaults off, so it stays
  inert). No upstream gst-0.10 vp9dec ever existed — this is a hand-backport.
- **matroska** from `gst-plugins-good-0.10.31/gst/matroska`, + `src/matroska-vp9.patch` (2012
  matroska tagged VP9 as `x-unknown`). Needs `-Dguintptr=gsize` (glib 2.18+ type; device is 2.16),
  an `_stdint.h` shim, generated pbutils/version headers, and links libgstriff/tag/pbutils + zlib.
- **speexdec** from `gst-plugins-good-0.10.31/ext/speex`, reusing the bundled `GstAudioDecoder`;
  needs a constructed `speex_config_types.h`; `gst_tag_list_from_vorbiscomment_buffer` no-op shim.

The `src/` dir holds the non-trivial derived source (vp9dec) and the matroska VP9 patch; the rest is
mechanical (see the cross-compile gotchas in `../gst-opus-codec/README.md`, which all apply here).

## Not done (and why)

- **Theora**: no `libtheora` on device; low value (obsolete). Skipped.
- **VP9/VP8 encode, Theora**: encode not needed for playback.
- **HEVC/H.265, AV1**: no gst-0.10 element + far too heavy for the hardware. Out of scope.
