# gst-opus-codec — native Opus for the TouchPad's stock media pipeline

Backports **Opus** into the device's **gstreamer-0.10** pipeline so the stock **Video/Music
players** — and Messaging voice-note playback — decode WhatsApp / Telegram / Signal voice notes
(**Opus-in-Ogg**) natively. Fast, no Atlas, no transcode, no file bloat.

## The problem

- The system pipeline (`mediaserver`, gstreamer **0.10.29** / glib **2.16.6** / gst-plugins-base
  **0.10.35**, all from HP's 2011 build) has `oggdemux` + `vorbisdec` but **no `opusdec`**, and
  `libavcodec.52` (via `gst-ffmpeg`) is too old for Opus.
- Its 2011 `oggdemux` doesn't know the Opus-in-Ogg mapping — it tags the stream
  `application/x-unknown`, so even adding `opusdec` isn't enough.
- Atlas *does* have Opus, but its `libgstopus` is gstreamer **1.0** — ABI-incompatible with the
  system's 0.10, and playing via Atlas was slow / unreliable (about:blank, WebKit file-origin).

## What we ship

Two ABI-matched gstreamer-0.10 plugins + the codec lib:

| File | Provides |
|------|----------|
| `prebuilt/libgstopus.so` | `opusdec` (play) **and** `opusenc` (record/send voice notes) |
| `prebuilt/libgstogg.so`  | Opus-aware `oggdemux` + `oggmux` (drop-in superset of the stock ogg plugin — vorbis/theora still work) |
| `prebuilt/libopus.so.0`  | the Opus codec the plugins link (originally shipped inside the Teams app) |

Install: `./install-gst-opus.sh` (backs up the stock `libgstogg.so` → `libgstogg.so.orig`, pushes
the libs to `/usr/lib[/gstreamer-0.10]`, drops the registry so it re-scans). Verified test:

```
gst-launch-0.10 filesrc location=<voice>.ogg ! oggdemux ! opusdec ! audioconvert ! alsasink
```

reaches `PLAYING → EOS` with sound; `decodebin2` auto-plugs `opusdec` (so playbin/the stock
players pick it up automatically).

## How it was built (the ABI puzzle)

Cross-built with the **PalmPDK** toolchain (`arm-none-linux-gnueabi-gcc` 4.3.3) against **HP's exact
open-source drops** (`gstreamer-0.10.29`, `glib-2.16.6`) so the ABI matches the device bit-for-bit.

- **Opus element** from `gst-plugins-bad-0.10.23` (first release with Opus). It needs
  `GstAudioDecoder`/`GstAudioEncoder`, which in that era lived in **gst-plugins-base 0.10.36** (the
  device has 0.10.35), so those base classes — plus `GstAudioInfo` (`audio.c`/`multichannel.c`) —
  are **bundled into the plugin**.
- **Ogg element** from `gst-plugins-base-0.10.36` (the version whose `gstoggstream.c` learned the
  Opus mapping), with `GstCollectPads2` (gstreamer core 0.10.36) bundled for `oggmux`. The niche
  OGM/AVI parsers were dropped (they pull `libgstriff` internals).

Cross-compile subtleties that bit us (documented so nobody re-derives them):

1. **`glibconfig.h`** must be the **glib-2.16 armv7** one (from the doctor305 staging). A newer
   glib's (2.52) removed `GStaticMutex`, which 2.16's `gthread.h` still references.
2. **`gstconfig.h`** disable-flags must match the device build: `GST_DISABLE_LOADSAVE`/`XML`
   **defined** (the device's `libgstreamer` doesn't link libxml2), `GST_DISABLE_GST_DEBUG`
   **undefined** (debug enabled). Defining a flag as `0` still disables it — the headers test
   `#ifdef`, not the value — and these flags change core struct ABI.
3. Generated headers (`gstconfig.h`, `gstversion.h`, `gstenumtypes.h`, `gstmarshal.h`,
   `audio-enumtypes.h`) were produced with `glib-mkenums`/`glib-genmarshal` + hand-filled configs.
4. Compatibility **shims** for symbols newer than the device's 0.10.29/0.10.35:
   `gst_element_class_add_static_pad_template` (0.10.32+), `gst_tag_list_to_vorbiscomment_buffer`
   (minimal builder), `GST_TRACE_OBJECT`/`GST_TRACE` (0.10.30+ log level → no-op).
5. The plugins **link** `libgstreamer/base/audio/tag/riff-0.10` + `libopus`/`libogg` so those
   symbols resolve when the plugin is dlopen'd (they aren't all auto-loaded with `libgstreamer`).

`build-gst-opus.sh` records the recipe; the prebuilt `.so`s are the validated output.

## Bonus: `opusenc`

`libgstopus.so` also registers **`opusenc`**, so the device can *encode* Opus — the foundation for
**recording and sending** voice notes (WhatsApp/Telegram/Signal expect `audio/ogg; codecs=opus`),
paired with the Opus-aware `oggmux` in `libgstogg.so`.
