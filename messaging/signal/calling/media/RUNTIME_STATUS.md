# signal_media — on-device runtime status (2026-07-21 overnight)

## Build: ✅ cross-compiles clean to ARM
`build-signal-media.sh` → `signal_media` (ELF ARM) + `libsignalmedia.a`. Exports
`signal_media_start`, `signal_media_add_remote_candidate`, `signal_media_stop`,
`signal_media_loopback_selftest`, `signal_negotiate_srtp_keys`. All NEEDED libs
(gstreamer/app/base, libnice.so.10, libsrtp2.so.1, libopus.so.0, libcrypto.so.3,
glib) resolve in the Atlas wpe-252 deviceroot. srtp_kdf matches the Python reference.

## Standalone `--loopback` on device: ⚠ BLOCKED by the wpe-glibc runtime (NOT a code bug)
The gst/nice/srtp libs live in the Atlas **wpe-252** deviceroot and are built against a
**newer glibc** (`/media/internal/wpe-glibc/`), not the device's system glibc. Running the
standalone binary hits the classic wpe-glibc-standalone trap:
- native interpreter (`/lib/ld-linux.so.3`) + `wpe-glibc/lib` on LD_LIBRARY_PATH → crashes at
  load (system loader vs newer libc mismatch), no output.
- invoking the wpe-glibc loader explicitly (`.../wpe-glibc/lib/ld-linux.so.3 signal_media`) → gets
  all the way to gst plugin loading, then aborts: `GLib-ERROR getauxval() failed: No such file or
  directory` (auxv mangled when the loader is invoked explicitly on this 2.6.35 kernel).
- ⚠ Also: `export`ing the wpe LD_LIBRARY_PATH into a shell BREAKS busybox (tail/ls segfault) — a
  red herring seen while debugging. Always `env VAR=... cmd` (scoped), never `export`, and read
  logs from a CLEAN shell.

## Why this doesn't block the real integration
The Telegram plugin (libtelegram-tdlib.so, same wpe-252 libs incl. libtgvoip) runs FINE because it
is a **.so loaded into imlibpurpletransport**, a process already launched with the correct wpe-glibc
env (its LD_LIBRARY_PATH = `sslfix:wpe-glibc/lib:...:wpe-252/lib:/usr/lib:/lib`). So the Signal media
engine should be built as a **library linked into the purple-presage plugin** (or driven from
`com.palm.signal.call`/call.c running in that transport), NOT as a standalone binary. Then it inherits
the working env and the getauxval/loader problems disappear.

## Morning path (recommended order)
1. **Preferred:** compile `signal_media.c` (minus its `main`/argv) into `libsignalmedia.a` and link it
   into the purple-presage plugin build (build-presage.sh); expose `signal_media_start/stop/
   add_remote_candidate`. Call it from call.c on a real Signal offer. The loopback self-test can then
   run in-process (or via a tiny plugin command) with the correct env.
2. **If you still want the standalone loopback:** run it inside the transport's exact environment, or
   `patchelf --set-interpreter /media/internal/wpe-glibc/lib/ld-linux.so.3 --set-rpath <full path>`
   the binary so it runs natively with the wpe-glibc loader (untried; may still hit getauxval — the
   in-process path is the safer bet).
3. Wire the presage bridge (README §"presage integration"): generate our X25519 keypair, build+send
   the Answer opaque (call_media.rs::encode_answer_opaque already verified), relay ICE both ways
   (call_media.rs::{encode,decode}_ice_opaque), start/stop the engine, audiod scenario via call.c.

## Verified so far (host)
- srtp_kdf.c == srtp_kdf.py (RFC7748 X25519 + RFC5869 HKDF vectors) — SRTP key derivation correct.
- call_media.rs opaque encode/decode — byte-identical to a real captured offer + ICE (3 tests pass).
- signal_media cross-links clean; every gst element/property/signal name verified present in staging.
UNVERIFIED (needs the in-process run): gst caps negotiation (srtpenc↔srtpdec, OPUS RTP), SRTP-GCM
interop with real Signal, and the ALSA voip/voipsource→pulse routing.
