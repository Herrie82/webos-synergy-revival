# WebM / VP9 playback on webOS (TouchPad)

Getting a WebM/VP9 `<video>` to play in a stock webOS app (Messaging, Browser) needs **four**
independent pieces. This directory holds piece #4; the others live in sibling `device-setup/` dirs.

| # | Layer | What / where |
|---|-------|--------------|
| 1 | **Codecs** | gst-0.10 `vp8dec`/`vp9dec`/`matroskademux` in the media server's registry — `../gst-video-codecs/` |
| 2 | **Autoplug** | media-pipeline `LD_PRELOAD` shim so decodebin routes VP8/VP9 to the software decoder instead of the H.264-only hardware path — `../videoplayer-webm/` (`mp_autoplug.c`) |
| 3 | **WebKit gate** | `canPlayType("video/webm")` — patched here (`install-webkit-webm-mime.sh`) |
| 4 | **App markup** | inline video emits `<source type="video/webm">` — messaging change lives in the `core-apps` repo |

## Why the WebKit gate needs a binary patch

Every app/browser `<video>` goes through `libWebKitLuna`'s `MediaPlayerPrivate(Palm)` → the media
server. WebKit first checks `supportsType()`, whose MIME set is a **hardcoded list of ~21 compiled
strings** (`GetTypeCache`) — `video/mp4`, the WMV/ASF family, etc., but **no `video/webm`**. It is
not config-driven (not `appinfo.json`, not the platform `MimeSystem` — those feed the resource-handler
system, which never reaches WebKit's decode gate). So the only lever is the binary.

`install-webkit-webm-mime.sh` overwrites the dead-weight `video/x-ms-wmv` `.rodata` string (WMV can't
be decoded on this device anyway) with `video/webm` + NUL padding — a pure string swap, no code moves,
reversible from the on-device backup at `/media/internal/libWebKitLuna.so.prewebm`. That one string
feeds both the `supportsType` set and the extension→mime map, so `canPlayType("video/webm")` returns
`"maybe"` and WebM loads natively. Restart the UI (`killall LunaSysMgr`) to load the patched lib.

## Performance note

VP9 decode is software (no VP9 hardware on the OMAP4). The shim requests `threads=2` and libvpx is
built with NEON (`../gst-video-codecs`), but decode stays CPU-bound: VP9's serial entropy/bitstream
stage plus the `ffmpegcolorspace` I420→RGB conversion and WebKit compositing dominate, none of which
NEON accelerates. Small clips play fine; large/high-res clips are choppy. This is a hardware ceiling.
