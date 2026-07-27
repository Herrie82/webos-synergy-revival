# videoplayer-webm — make the stock Video player actually play WebM/VP8/VP9

> ⚠️ **DO NOT INSTALL THE AUTOPLUG SHIM ON A DEVICE WHERE mp4 VIDEO MATTERS.**
> The `mp_autoplug.c` LD_PRELOAD shim (Gate 2 below) **breaks H.264 (mp4) video playback** — verified
> on device by clean-boot A/B (2026-07): with the shim active, mp4 video sessions never get created
> (the player spins; the media resource arbiter logs `requestPipeline restore timeout` / `unsent
> QueryName`); with it OFF, the same mp4 decodes and plays via the Snapdragon S3 OMX hardware decoder.
> The `README`'s earlier "mp3/mp4 still play normally through it" claim was **WRONG**. Since every
> received IM video is H.264 mp4 (WhatsApp/Teams/Signal/Telegram) and **none are WebM**, the shim's
> only benefit does not apply to messaging — so the shim is kept **OFF** (stock media-pipeline). The
> mediastream `<source>`-mislabel patch (Gate 1) is harmless and independent; only the autoplug shim is
> the problem. `install-videoplayer-webm.sh` no longer enables the shim unless `MP_SHIM=1` is set.

The `../gst-video-codecs` package puts `vp8dec`/`vp9dec`/`matroskademux` into the gstreamer-0.10
registry, so the pipeline *can* decode WebM. But the stock **Video player** still wouldn't play a
`.webm`: it opened, spun forever, then errored. This package fixes the two gates that sit *above* the
codecs. Pairs with `../gst-video-codecs` + `../gst-opus-codec` (install those first).

## The two gates (both fixed here)

**Gate 1 — WebKit won't even hand WebM to the media server.** Every app `<video>`/`<audio>` on the
TouchPad goes through `libWebKitLuna`'s **only** media backend, `MediaPlayerPrivatePalm`, which asks
`palm://com.palm.mediad.MediaPlayer` to play the URI. But `MediaPlayerPrivatePalm::supportsType()` has
a **fixed type list with no `video/webm`** (it does have `video/ogg`, `audio/ogg`, `video/mp4`, …). So
`<video src="x.webm">` fails `canPlayType` and no pipeline is ever created — confirmed: an mp4 spawns
a `MediaPlayerSession`, a webm spawns nothing.

*Fix:* the media server decodes by **typefinding the real bytes** (generic `decodebin`), so the mime
WebKit was given doesn't matter for demuxing — only for engine selection. We mislabel webm/mkv as a
`<source type="video/ogg">` (a type WebKit *does* accept). WebKit instantiates its engine, the media
server sniffs the actual bytes and plays the real WebM. The stock Video player's `<video>` is driven
by the shared **`mediastream`** framework's `StreamingPlayEngine` (`this.player.src = url`), so we
patch that one spot. Only webm/mkv are rerouted; every other format keeps its direct `src`.

**Gate 2 — the pipeline reaches for the hardware decoder and chokes on VP9.** Once WebKit hands over
the WebM, the media server's `PlaybinPipeline` autoplug **prefers the SoC `palmvideodecoder`** (which
only accepts `video/x-h264`/`x-h263`). Fed VP9 it throws `PalmOmxVideoDecoder ... chain error -2` and
the player just buffers forever. Plain `gst-launch playbin2` plays the same file fine because it uses
the default rank-based autoplug and picks `vp9dec`.

*Fix:* an LD_PRELOAD shim (`libmp-autoplug.so`) into `media-pipeline`. It intercepts
`g_signal_connect_data` and, for `decodebin`'s `autoplug-select`/`autoplug-continue`, installs the
**plain default policy** (try every factory by rank / keep decoding to raw) instead of the pipeline's
custom handlers. Hardware H.264 still wins by rank for mp4; for `video/x-vp9` the only candidate is
`vp9dec`, so it gets picked. The shim never calls the pipeline's original C++ handler (doing so
SIGABRTs), so it's crash-safe — verified: mp3/mp4 still play normally through it.

## What we ship

| File | Role |
|------|------|
| `prebuilt/libmp-autoplug.so`     | the decodebin autoplug shim (Gate 2) — LD_PRELOADed into media-pipeline |
| `media-pipeline.wrapper`         | replacement `/usr/bin/media-pipeline` that adds the shim to `LD_PRELOAD` |
| `src/mp_autoplug.c`              | shim source |
| `build-mp-autoplug.sh`           | rebuild the shim (PalmPDK gcc; needs the gst-0.10/glib-2.16 headers) |
| `src/patch-mediastream.py`       | the Gate-1 `<source type="video/ogg">` mislabel, applied to the framework JS |
| `install-videoplayer-webm.sh`    | does all of the above, idempotently, with on-device `.orig` backups |

## Install

```
./install-videoplayer-webm.sh
```

Then, on the device **with the screen on** (the player only creates a session when foregrounded):

```
luna-send -n 1 luna://com.palm.applicationManager/launch \
  '{"id":"com.palm.app.videoplayer","params":{"target":"file:///media/internal/<x>.webm"}}'
```

Verified: `/var/log/messages` shows `pipeline0 ... is now PLAYING` and **no** `palmvideodecoder ...
GSTREAMER: ERROR`.

## Notes / revert

- **Messaging** inline WebM/Opus rides the same media path, but its app-side `<source>` mislabel lives
  in the **core-apps** repo (`com.palm.app.messaging` `ConversationItem.js`), not here.
- The installer touches system files under `/usr/lib`, `/usr/bin` and `/usr/palm/frameworks`, all with
  `.orig` (or `.wrapper.orig`) backups. To revert:
  ```
  cp /usr/bin/media-pipeline.wrapper.orig /usr/bin/media-pipeline
  for f in 24mediastream.js 24/concatenated.js 24/javascript/StreamingPlayEngine.js; do
    F=/usr/palm/frameworks/mediastream/submission/$f; cp "$F.orig" "$F"; done
  rm -f /usr/lib/libmp-autoplug.so; stop mediaserver; start mediaserver
  ```
