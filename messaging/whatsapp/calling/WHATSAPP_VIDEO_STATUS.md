# WhatsApp video calling — status

## TL;DR

**Go/network media path: validated live, both directions.** `examples/videoloop` placed a real
two-account WhatsApp video call and streamed a synthetic clip end to end — 240/240 access units
sent and received, byte-identical to the source, decoded clean in ffmpeg. This clears the
`NOT VALIDATED` markers on `Call.SendVideo`/`Call.ReceiveVideo`/`videoSender` in meowcaller.

**Native device side: root cause found and fixed. `videoCaptureStart` AND `videoPlayerStart` both
now return `true` and a real GStreamer `ManagedClonkPipeline` gets constructed on-device, confirmed
live for both directions.** webOS's Skype
video calling never had its own media stack — it drove a general-purpose real-time video-call
session type (`clonk`) already built into the stock `mediaserver` daemon, the same process that
does stock H.264 file playback. That session type is still present and instantiable on this exact
TouchPad, confirmed live. The real per-session LS2 handler class, `media::luna::ClonkServer`, was
found directly in `libmedia-api.so`'s symbol table.

**Part 5/6's "ClonkServer business object is null" theory was wrong** — corrected in Part 8 below.
The actual bug was the **payload shape**: earlier disassembly of the array-*indexing* code
(`JValue::operator[](int)`, applied to a JValue already called `args`) was misread as "the whole
payload is a bare array." Disassembling `LunaInterface::getArguments` directly (the shared helper
every action method calls first) shows it does `pbnjson::JDomParser::parse(payload, ...)` and then
**`dom["args"]`**, requiring *that* to be an array — the literal string `"args"` lives in
`libmedia-api.so`'s `.rodata` at `0x153f5c`. A bare top-level array parses as valid JSON but fails
`dom["args"].isArray()` (indexing an array by a string key isn't an array), which silently sets an
internal `ok` flag false and produces exactly the clean, textless `{"returnValue":false}` we'd been
seeing — without the code ever reaching the real virtual dispatch into the business object. The fix
is trivial: wrap every action-method payload in `{"args":[...]}` — e.g.
`videoCaptureStart {"args":[320,240,15,400000]}`, `setDeviceUri {"args":["device://camera/front"]}`,
`videoCaptureStop {"args":[]}` (stop takes no business params but still requires the wrapper key to
exist, or it skips the real call too). Confirmed live via `clonk_probe`: `videoCaptureStart` now
returns `{"returnValue":true}`, `getVideoCaptureHasPipeline` flips to `true`, and
`/var/log/messages` shows `mediaserver` actually constructing a `ManagedClonkPipeline` for the
session (torn down on session end, `ManagedClonkPipeline::~ManagedClonkPipeline() pipeline not
suspended` — a real, not-yet-graceful-shutdown pipeline, i.e. real pipeline activity, not a no-op).
See Part 8 for the full disassembly trail. Separately, the entire Phone-app UI integration contract
(Part 4) is fully specified from real `core-apps` source — no further research needed there, only
implementation. Camera contention from Atlas's `qcamd` was checked and ruled out directly via
`/proc/<pid>/fd`.

**Architecture pivot (Part 9): the planned "shm frame handoff" is very likely not the real
integration point.** Chasing it down found the actual mechanism (`VideoSink`'s SysV shm segment,
keyed by a private heap pointer no external process could predict), but zero segments ever appeared
during a real live test, and `ClonkServer`'s full ~50-method LS2 surface has no frame/buffer getter
at all. What it *does* expose — `H264SenderConstraints`/`H264SenderParameters`/
`H264ReceiverParameters`, whose fields decode via disassembly to the literal RFC 6184 SDP `fmtp`
parameter names (`max-mbps`, `max-fs`, `max-br`, etc.) — plus `test_GenerateCapturePcap`/
`test_GenerateReceivePcap` test hooks, is strong evidence `mediaserver`'s `ClonkPipeline` does full
H.264 encode/RTP-payload/network-send (and the receive mirror) *internally*, not via a raw-frame
handoff to an external process. The open question is now **how that RTP transport gets pointed at a
destination** (no address/port/socket property found yet) — see Part 9 for the full trail.

**Resolved (Part 10): the RTP boundary is `skypevideosrc`/`skypevideosink`, backed by a real, embedded
copy of Skype's own SkypeKit SDK.** `libpalmgstskype.so` isn't webOS-specific glue — `nm -C -D` and
`strings` on it turn up an entire `Sid::` SkypeKit namespace (`Sid::Protocol::BinClient`,
`Sid::UnixSocket`, `SkypeVideoRTPInterface`, source path
`Inc/skypekit/ipc/cpp/AVTransport/SocketTransport.cpp`). The actual data plane is two fixed-name
**abstract-namespace Unix domain sockets** — `/tmp/vidrtp_to_skypekit_key` and
`/tmp/vidrtp_from_skypekit_key` (plus a PCM pair for audio) — carrying RTP packets wrapped in
SkypeKit's own binary RPC framing (`wr_call_lst`/`ProcessCall`). This is genuinely good news: it's a
well-known IPC boundary SkypeKit was always designed for an external process to plug into, not
something to reverse-engineer from nothing. **Confirmed the exact role split:** `mediaserver` is the
**server** (listens) on `vidrtp_from_skypekit_key` for incoming video, and the **client** (dials out)
on `vidrtp_to_skypekit_key` for outgoing video — so a bridge needs to bind the first and connect to
the second.

**Correction (Part 11): the wire-protocol question was premature.** Built a tool
(`vidrtp_sniffer.c`) to capture real bytes off `vidrtp_to_skypekit_key` instead of guessing the byte
format — and `mediaserver` never connected at all, in two full test runs. Root-caused with
`--gst-debug=4`: the GStreamer pipelines never actually reach a linked, running state, so there's no
real RTP traffic yet regardless of the SkypeKit socket layer. Found two concrete, ordinary
GStreamer-level problems: (1) **capture side, fixed** — `camsrc` only supports exactly
`640x480`/`320x240`/`160x128`, all fixed at `framerate=30`, and `clonk_probe` had been requesting
`framerate=15`; switched to `30` and the caps-negotiation error is gone. (2) **player side, found,
turned out to be a non-issue** — `gst_skype_video_src_change_state` warns
`"resolution not set on capsfilter"`, but Part 12 proved this does **not** block `RunVideoHost()`
or the SkypeKit socket layer at all; it just needs more than a few seconds. See Part 12.

**Resolved (Part 12): real connectivity to `mediaserver`'s live SkypeKit socket is now proven.**
Confirmed `RunVideoHost()` genuinely starts on its own given enough time (`/tmp/vidrtp_from_skypekit_key`
appears reliably and stays bound), and via `strace` confirmed the listening window is a real multi-second
window, not a race. The one thing actually blocking every connection attempt was a simple bug in the
test tool, not mediaserver: the abstract socket name is the literal string `"/tmp/vidrtp_from_skypekit_key"`
(`/tmp/` included, despite being an abstract name with no real filesystem path) — `vidrtp_sniffer` was
only passing the `vidrtp_from_skypekit_key` suffix. Fixed, and `vidrtp_sniffer client
/tmp/vidrtp_from_skypekit_key ...` now connects successfully every time. Held it open 16+ seconds:
`mediaserver` sends nothing unprompted, confirming it's the passive `Sid::Protocol::BinServer` side,
waiting to read an RPC call from us. **The only remaining piece is implementing enough of
`Sid::Protocol::BinClient`'s wire framing to send one** — `mediaserver` is proven ready and waiting.
See Part 12 for the full trail.

**Decoded (Part 13) and confirmed working live (Part 14): a real, hand-constructed `RtpPacketReceived`
RPC call successfully reaches and is processed by `mediaserver`.** Rather than reverse-engineer the
exact wire bytes (real but genuinely risky work — two hand-arithmetic mistakes surfaced in Part 13
alone), pivoted to **linking a small test program directly against the real, extracted
`libpalmgstskype.so`** and calling its actual compiled `AVTransportWrapper`/`Sid::Protocol::BinClient`/
`SEBinary`/`wr_call_lst` functions with our own arguments — reusing 100% of the real, tested wire
encoder instead of reimplementing it. `RtpPacketReceived`'s exact command ID (**20**) and field-table
location were found via verified relocation-table lookups, not guessed. Built, iteratively debugged
live on-device (a `SIGSEGV` handler added directly to the test tool, since gdb remote debugging has
been unreliable all session and this device's `strace` is too old to decode fault addresses), and
**it works**: `wr_call_lst` returns success, `mediaserver` stays fully healthy, and `--gst-debug=4`
shows the call had a real, visible effect — `clonkvhsrc`'s internal `rtp` element, which *never*
showed any lifecycle activity in any earlier test this session, now logs real `unlock`/`create`
activity in response. This is the single hardest open question of the whole investigation — "can we
actually talk to mediaserver's SkypeKit interface without the real SDK" — now demonstrated, not just
theorized. See Parts 13–14 for the full trail, including the two bugs found and fixed via live
testing (an `SEBinary` initial-state bug and a field-table-indexing bug).

**Resolved (Part 15): the `"wrong state (unlocked)"` message from Part 14 is normal `GstBaseSrc`
teardown behavior, not a sequencing bug.** Disassembly of `gst_skype_rtp_src_create` showed it's the
standard pattern of checking an `unlock()`-set flag before pulling from its internal queue. Retested
with the player-active window extended from 25s to 90s: the message appeared exactly once, timestamped
to the exact moment of our own test's intentional teardown (~92s in, right after `unlock()` fires),
and nowhere else in a 19150-line capture. The `rtp` element's src pad links and starts its streaming
task cleanly at ~7s, well before any teardown. Nothing left to chase on the incoming (`RtpPacketReceived`)
path. See Part 15 for the full trail.

**Found and fixed a real firmware bug blocking the outgoing (capture) path entirely (Part 16), but a
further blocker remains.** `ClonkPipeline::setCamCapsFilter()` reads the wrong offsets (`+4`/`+8`
instead of `+0`/`+4`) off the `VideoSettings` object when building `camsrc`'s downstream capsfilter,
so `videoCaptureStart(w,h,fps,bitrate)`'s own `h`/`fps` values silently ended up as the applied
`width`/`height` — guaranteeing "Could not negotiate format" every time. Confirmed via disassembly
and fixed with an LS2-level workaround (shift `h`/`fps` argument values by one slot); with the fix,
`camsrc` reaches `PLAYING`, `getVideoCaptureActive` flips `true`, and the whole capture→encoder→sink
chain runs with zero GStreamer errors — the first time capture has ever genuinely worked this session.
**Resolved (Part 17): the outbound socket connect is gated behind a client first connecting to the
*incoming* socket.** Disassembly of `GstSkypeInstance::RunVideoHost()` shows a strict two-phase
structure — it loops on `AVServer::Connect` (bind+listen+accept on `/tmp/vidrtp_from_skypekit_key`)
and only reaches the outbound `AVTransportWrapper::Connect` call once that accept succeeds. Confirmed
live: connecting `skypekit_send_test` to the inbound socket while `vidrtp_sniffer` waited on the
outbound one made `mediaserver` dial out and send 535 real bytes within moments — the first outbound
SkypeKit traffic captured all session. See Part 17 for the full trail and the captured bytes.

**Decoded (Part 18): the 535-byte capture is a real, standard RTP/H.264 packet.** Built
`skypekit_decode_test` — same safe "link against the real `.so`" technique as Part 14, applied to
reading instead of writing — to replay the captured bytes through the real, compiled
`Sid::Protocol::BinServer::rd_call`/`rd_parms` decoder rather than hand-parsing them. Found every
message starts with a 2-byte sync+type header (`0x5a` fixed sync byte, then a type byte — `0x52`='R'
for a call), consumed by `rd_command` before `rd_call`. Once framed correctly, decoded a clean
525-byte payload that is unambiguously a standards-compliant RTP packet carrying genuine H.264 video:
valid RTP header (version 2, marker set, payload type 96 matching the pipeline's own negotiated caps,
real sequence/timestamp/SSRC), followed by a valid H.264 NAL unit (`0x41` = non-IDR coded slice) as
the very first payload byte. No SkypeKit-proprietary frame format to reverse-engineer beyond the
already-decoded framing — the payload itself is ordinary RTP/H.264, matching what
`meowcaller`/`whatsmeow`'s `Call.SendVideo` already expects. See Part 18 for the full trail.

---

## Part 1 — meowcaller video media path (done tonight, no device needed)

Built `examples/videoloop`: a two-account loopback tool that places a real 1:1 WhatsApp video call
and streams a synthetic H.264 clip from caller to callee through `Call.SendVideo`, recording what
`Call.ReceiveVideo` gets back.

**Result:** 240/240 Annex-B access units sent and received (cross-checked against
`diag/callee/video.jsonl`'s frame count), `received.h264` byte-length matched the source, decoded
with zero ffmpeg errors. Both directions of meowcaller's video media path work over the real
relay. See `CHANGELOG.md` and the updated comments in `livecall.go`/`engine_media.go`.

Also fixed along the way: phone-number-code pairing (`link_code_companion_reg`) returns a bare
`400 bad-request` against live WhatsApp servers regardless of number or whatsmeow version —
`examples/videoloop` uses standard QR pairing instead (works reliably; renders a scannable PNG via
`github.com/skip2/go-qrcode` in addition to the terminal QR).

**Not yet done:** bumping the same whatsmeow version into `purple-combined`'s own go.mod if
useful, and hooking a real webcam-encoded H.264 source into a live call (see Part 2).

## Part 2 — how Skype video calling actually worked on this hardware

Reverse-engineered from the shipped, unstripped `mediaserver` binary (full C++ symbols) plus a
webOS 3.0.5 rootfs image, then confirmed live against the connected TouchPad
(`Nova-HP-Topaz` / `linux-palm-tenderloin`, novacom device `topaz-linux`).

### The architecture

`skypem` (the Skype signaling mediator — analogous to our `glue/call.c`) **never links any media
library**. It drives everything over LS2 against `com.palm.mediad`, which is owned entirely by
`/usr/bin/mediaserver` — **the same daemon that already does stock H.264 file playback** via
`palmvideodecoder`. `mediaserver` exposes three session types:

- `service/playback` — stock file playback (what the Video app uses).
- `service/captureV3` — photo/video/audio capture (what voice-note recording uses).
- `service/clonk` — **a third, purpose-built real-time two-way video-call session type**, used by
  Skype but implemented as a generic facility, not Skype-specific.

Calling `palm://com.palm.mediad/service/clonk` with `{}` allocates a `media::pipeline::ClonkSession`
and returns a per-call bus name (confirmed live: `palm://com.palm.mediad.Clonk_NNNN/`). Symbols
recovered from `mediaserver` (full list in git history of this file / session transcript) show:

- **Capture (outgoing):** property `deviceUri` (e.g. `device://camera/front`, confirmed default),
  `videoCaptureActive` (bool — **setting this true is what starts capture**, internally invoking
  `ClonkSession::videoCaptureStart(w,h,fps,bitrate)`), tunable via `h264SenderConstraints`/
  `h264SenderParameters`/`videoBitrate`.
- **Playback (incoming):** `videoPlayerActive`, `h264ReceiverParameters`, wired internally to a
  GStreamer bin literally named `clonk_vplay_h264dec` — real H.264 decode, distinct from the
  file-playback `palmvideodecoder` path.
- **Picture-in-picture:** `pip`/`PipSettings`/`getTranslatedPipPosition` — local camera preview
  overlaid on remote video.
- Keyframe requests, camera orientation (`getLocalVideoRotation`/`getRemoteVideoRotation`), CPU
  scaling hints (`setCpuScalingForVideo`) — all present.

The GStreamer plugin providing the actual `skypevideosrc`/`skypevideosink` elements
(`libpalmgstskype.so`, confirmed caps `video/x-h264`) is exactly what `skype-disable/remove-skype.sh`
moved to `/var/skype-disabled-backup` — **that script never touched `libmedia-clonk.so` or
`mediaserver` itself**, only the Skype-specific launch path.

### The LS2 calling convention (confirmed live)

Property accessors are named identically to the C++ getters/setters and respond instantly:

```
luna-send -n 1 palm://com.palm.mediad.Clonk_NNNN/getDeviceUri '{}'
  -> {"propertyRead":{"name":"deviceUri","value":"device://camera/front"},"returnValue":true}
luna-send -n 1 palm://com.palm.mediad.Clonk_NNNN/getVideoCaptureActive '{}'
  -> {"propertyRead":{"name":"videoCaptureActive","value":false},"returnValue":true}
```

`getVideoBitrate`/`getCaptureDevices`/`getError` hang instead of erroring — likely the same PJSON
"Attempt to append into non-array" bug logged at every `mediaserver` startup, hitting
array/complex-typed properties specifically. Scalar bool/string properties are unaffected.

### The methodology trap (important for any further testing)

**A Clonk session's lifetime is tied to its creating client's LS2 connection.** Confirmed live:
killing the `luna-send` process that created a session immediately logs
`Stopping session palm://com.palm.mediad.Clonk_NNNN/` in `/var/log/messages`. Since every
`luna-send -n 1 ...` invocation is a *separate* one-shot process, a sequence of independent
`luna-send` calls against the same session tears the session down after the very first call — every
"TIMED OUT" seen while probing `setVideoCaptureActive` this way is **confounded** and proves
nothing about whether the call itself works.

**Fix:** `clonk_probe.c` (new, this directory) holds one `LSHandle` for the whole sequence — create
session → `getDeviceUri` → try candidate write calls → wait 3s → check status → wait 2s → cleanup
— exactly like a real client (`skypem`) would. This is the *first* methodologically-valid test of
whether any given write call actually starts a pipeline. Results are in Part 3.

## Part 3 — live test results (after the reboot below) and where the trail goes cold

`clonk_probe` ran correctly (persistent connection, no confounding) and got a clean, definitive
answer: **`setVideoCaptureActive` is not a registered method** —
`{"returnValue":false,"errorCode":-1,"errorText":"Unknown method \"setVideoCaptureActive\" for
category \"/\""}`. This is a real error, not a hang, and `videoCaptureHasPipeline` stayed `false`
throughout — the test never touched the camera.

Since `getDeviceUri`/`getVideoCaptureActive`/`getVideoCaptureHasPipeline` all work as literal
per-property getters, tried every plausible corresponding write convention, all cleanly rejected
the same way:

- `set` with `{"name":"videoCaptureActive","value":true}` → `Unknown method "set"`
- `set` with `{"videoCaptureActive":true}` → `Unknown method "set"`
- `videoCaptureActive` (bare property name) with `{"value":true}` → `Unknown method
  "videoCaptureActive"`
- `videoCapture` (no suffix) with `{"active":true}` / `{"value":true}` → `Unknown method
  "videoCapture"`
- Passing `{"videoCaptureActive":true,"deviceUri":"..."}` directly in the *session-creation* call
  (create-with-options theory) — session created fine, but the extra fields were silently
  ignored (`getVideoCaptureActive` still read back `false` afterward).

**Conclusion: guessing the write method name from the C++ symbol table is exhausted.** Plain
`strings` also turned up `setVideoCaptureBitrate`/`setVideoCaptureFramerate` as bare (non-mangled)
strings, but these are almost certainly `__FUNCTION__` debug-log literals from the matching
`ClonkPipeline` methods (matched exactly by mangled `...E12__FUNCTION__` symbols nearby), not proof
of an LS2 registration. Also found in this pass: `palmvideoencoder` and `palmvideosink` — a stock
hardware H.264 **encoder** element in the same gst-0.10 `palm*` family as the confirmed-working
`palmvideodecoder`, distinct from the newer gst-omx `omxh264enc` that `webos-vc`'s history found
broken — worth keeping in mind for Part 2's outgoing-encode plan regardless of how the `clonk`
question resolves.

**Update — found it.** `media::luna::ClonkServer` (the actual per-session category handler) isn't
in `mediaserver` or `libmedia-clonk.so` at all — it's defined in **`libmedia-api.so`**, confirmed
via plain (non-mangled-guessing) `nm -C`. That symbol table is a complete, authoritative list of
every real LS2 method: `videoCaptureStart`/`videoCaptureStop`, `videoPlayerStart`/`videoPlayerStop`,
`audioCaptureStart`/`Stop`, `audioPlayerStart`/`Stop`, `setDeviceUri`, `setPip`/`getPip`,
`setError`/`getError`, `updatePipSettings`, plus every `getX`/`setX` pair for the full property
list from Part 2, and `test_ExerciseHog`/`test_SetAudioSrcProperties`. **`videoCaptureStart` — the
very first thing tried at the start of this whole investigation — was right all along.** It only
ever "hung" back then because of the session-lifetime bug (Part 2); it was never retested with the
fixed persistent-connection tool until now.

Retested live with `clonk_probe`: `videoCaptureStart` is now accepted (no more `Unknown method`),
returning a clean `{"returnValue":false}` — **and no `"Unable to instantiate Clonk VH
Source/ahSink"` pipeline error appeared in the log**, meaning this is very likely a parameter-shape
problem (wrong field names/types in the 4-arg `width,height,framerate,bitrate` call), not a
hardware or architecture dead end. Tried `{"width":320,"height":240,"framerate":15,"bitrate":400000}`
and `{"width":320,"height":240,"framerate":15}` (matching the plain-string field names `width`/
`height`/`framerate` found in `mediaserver`, since `bitrate` wasn't among them — it has its own
separate `videoBitrate` property) — both cleanly `false`, no pipeline errors either way.

**Update — disassembled it (skypem's own backend is defunct — Skype's servers shut down years
ago, and `skype-disable`'s removal broke its LS2/db8/account registration too, so `strace`-ing a
real call was never actually viable; static analysis was the only path).** `objdump -d` on
`ClonkServer::videoCaptureStart` in `libmedia-api.so` (ARM disassembly, cross toolchain at
`~/x-tools/arm-unknown-linux-gnueabi-gcc125/bin/arm-unknown-linux-gnueabi-objdump` — note: the
*unprefixed* `objdump` on this machine resolves to the host x86 one and fails with "can't
disassemble for architecture UNKNOWN" on these ~2011 EABI5 binaries; use the prefixed one) shows:

- Exactly **one** `LunaInterface::getArguments()` call. Its "name" argument resolves (traced
  through the PC-relative/GOT-relative address arithmetic — see git history of this file for the
  worked Python calculation) not to a JSON key, but to a `__PRETTY_FUNCTION__`-style debug string
  (`"static bool media::luna::ClonkServer::videoCaptureStart(LSHandl..."`) — i.e. that argument is
  only used for error-context logging, not as a lookup key.
- Followed by four `pbnjson::JValue::operator[](int)` calls with **literal integer indices 0, 1,
  2, 3**, each piped through `ClonkServer::unmarshallunsigned_long(JValue)`.

**Conclusion (incomplete — corrected in Part 8): the payload is a bare 4-element JSON array**
(`[width, height, framerate, bitrate]` in argument order — matching
`ClonkSession::videoCaptureStart(w,h,fps,bitrate)`'s C++ signature), not an object. `setDeviceUri`
was checked the same way and has the identical shape: `getArguments()` → `operator[](0)` →
`unmarshallstring()`, i.e. its payload is `["device://camera/front"]`, not `{"value":"..."}`.
**What this missed:** the `operator[](int)` calls index into the JValue *`getArguments()` itself
returns*, not the raw top-level payload — and `getArguments()` (traced fully in Part 8) internally
does `dom["args"]` before ever getting there, requiring the payload to be `{"args":[...]}`. A bare
array happens to *parse* fine, which is why this looked plausible at the time (see next paragraph:
it was "accepted", not rejected with "Unknown method") — it just never actually reaches the
`operator[](int)` calls at all, because `dom["args"]` on a bare array fails `isArray()` first and
short-circuits to a silent `false`.

Tested live: `videoCaptureStart` with `[320,240,15,400000]` is **accepted** (parses fine, no
crash) but still returns a bare `{"returnValue":false}` with no error text and — still — no
pipeline-instantiation error in the log. Investigated one concrete hypothesis (Atlas's own camera
daemon, `qcamd`, holding `/dev/video0`, since this device dual-runs the legacy webOS layer
alongside Atlas/webOS-ports and `qcamd` is exactly what `webos-vc`'s `getUserMedia` path uses) —
**ruled out**: checked `/proc/<qcamd-pid>/fd` directly, it wasn't holding the device open at all
(idle on a socket + its own shm segment, camera opened on-demand only).

**Update — proved (not theorized) exactly where it fails, via `strace`.** Attached `strace -f`
to the live, already-running `mediaserver` (no restart needed — `strace -f -tt -p <pid> -o
<logfile>`) and ran `clonk_probe` through it. The raw LS2 wire messages confirm both calls arrive
intact (`recv(45, "/\0videoCaptureStart\0[320,240,15,"..., 41, ...)`), but in the entire window
between that `recv` and the next one three seconds later, **there is no `open()` on any
`/dev/video*` node, no camera `ioctl`, nothing hardware-related at all**. Raising `mediaserver`'s
own `--gst-debug` to 4 (temporarily: `stop mediaserver`, run it manually in the foreground with
the flag, redirect output, `start mediaserver` again after — see git history for the exact script)
confirms the same thing from the GStreamer side: debug output stops right after basic init: no
pipeline, element, or pad activity is ever logged for our calls. **The failure is 100% in C++
business logic, before any camera or GStreamer code runs.**

Traced the call chain one level further to find *why*: disassembly of `videoCaptureStart` shows a
null-check on a pointer 16 bytes into the handler's `void *ctx` argument, followed by a vtable
call through it — if that pointer is null, the function returns `false` immediately (matches the
symptom exactly). Traced backward through session creation to find what populates it:
`LunaService::clonkPipeline` (session-open handler) → `MediaServer::openSession` (generic,
locking/refcounting machinery shared across all three session types) → dispatches via vtable to
`ManagedPipelineFactory::createClonkControl(ClonkState&)`, which **unconditionally constructs a
`ManagedClonkPipeline`** at session-open time via `new` + placement construction — no conditional
path, no missing-device branch. This actually *disproves* the obvious theory (that the control
object simply doesn't exist yet) — a control object is always created. Why the specific
pointer `ClonkServer` methods dereference is still null despite that needs one more level of
tracing (either into `ManagedClonkPipeline`'s own layout, or the `ClonkServer` constructor).

**Update — `videoPlayerStart` (the receive/decode direction, previously untested) fails the exact
same way.** Same disassembly convention confirmed (one `getArguments()`, two
`unmarshallunsigned_long(operator[](0/1))` calls → bare array `[width,height]`), same live result:
accepted, no error, clean `{"returnValue":false}`, no pipeline activity. **This is one shared root
cause blocking both directions, not two separate bugs** — fixing it once unlocks both send and
receive.

## Part 4 — the Phone app UI integration contract (fully mapped, from real source)

Checked `/home/herrie/Documents/GitHub/core-apps` (`com.palm.app.phone`) — there is no separate
"video app"; video calling is a scene inside the stock Phone app, built originally for Skype and
still fully intact. This closes out the entire render/UI side of the design, independent of the
native bug above:

- **`shared/activecall/VideoCall.js`** renders incoming video with a plain Enyo `Video` kind
  (`{name:"videoTag", kind:"Video", ...}`) — i.e. the same WebKit `MediaPlayerPrivatePalm` /
  `com.palm.mediad` backend already confirmed for stock file playback, not a custom native widget.
  `enableVideo(videoURI)` calls `this.$.videoTag.setSrc(videoURI)` directly.
- **`call.videoURI` *is* the clonk session's own LS2 URI.** Proven two ways: (1)
  `source/CallSynergizer.js:358-359` — `call.videoURI = payload.videoURI; enyo.application.Cache.videoURI = payload.videoURI;`
  reads it straight from our own `callStateQuery` subscription response (top-level field, not
  per-line); (2) `ActiveCall.js:251-252` logs it literally as `"CLONK IS " + enyo.application.Cache.videoURI`
  and assigns `this.clonkPipeline = enyo.application.Cache.videoURI`. (3) `VideoCall.js`'s PiP calls
  (`updatePipSettings`/`getPip`/`setPip`) are issued with no static `service:` in the component
  declaration — the target is passed per-call as `{service: this.videoURI}`, meaning it must
  literally be a valid LS2 service URI, i.e. `palm://com.palm.mediad.Clonk_NNNN/`.
- **`updatePipSettings`'s real JSON shape**, straight from `VideoCall.js:235`:
  `{args:[{top_left:{x,y}, bottom_right:{x2,y2}, scale, orientation}]}` — corner coordinates and a
  scale/orientation, not width/height. Matches the `PipSettings` marshalling we found in
  `ClonkServer`'s symbol table.
- **`changeMedia(id, outgoingVideo, incomingVideo)`** is called against the **per-transport call
  service** (`palm://com.palm.skype/` in the original code — for us, `com.palm.whatsapp.call`), not
  against the clonk session directly. This is the call-mediator's job: `glue/call.c` needs to
  implement this LS2 method itself and internally translate on/off requests into clonk session
  calls (`videoCaptureStart`/`Stop`, `videoPlayerStart`/`Stop`).
- **`callStateQuery` response contract**, from `CallSynergizer.js` around line 339-359 — fields our
  `com.palm.whatsapp.call` service needs to add, none of which exist in the current audio-only
  implementation:
  - top-level `videoURI` (the clonk session URI, once one exists for the active call).
  - per-line `outgoingVideo` / `incomingVideo` (booleans).
  - per-line `incomingVideoState`: `"unavailable" | "available" | "streaming"` (a tri-state, not
    just a bool — drives the contact-image vs. live-video display switch in `ActiveCall.js`).
  - `autoAcceptVideoCalls` / `allowVideoCalls` (policy flags; default `true` is fine per an existing
    comment in `ActiveCall.js` — "Default to true... once skypem_1.3-25 makes it into a build").

Net effect: the entire UI-facing contract is now fully specified from real, working source, not
guessed — `glue/call.c` knows exactly what to expose (`changeMedia` method,
`videoURI`/`outgoingVideo`/`incomingVideo`/`incomingVideoState` in `callStateQuery`) once the native
clonk bug is fixed. This part of "hook it up" needs no further research, only implementation.

## Part 5 — chasing the shared root cause further: two more findings, one dead end

> **Corrected in Part 8:** this entire line of investigation (Parts 5 and 6) turned out to be a
> dead end — `ctx+16` is never actually null; a null there hits `__assert_fail`, which never fired.
> The real bug was the JSON payload shape (`{"args":[...]}` vs. a bare array), found by reading the
> *rest* of `videoCaptureStart`'s disassembly and `getArguments` itself. Left below as a record of
> the (wrong) trail, not as current guidance — see Part 8 for what's actually true.

Went one level deeper on *why* the dispatch pointer at `ctx+16` is null:

- **`ClonkServer`'s own constructor is correct.** Disassembled
  `ClonkServer::ClonkServer(shared_ptr<Clonk>)` in `libmedia-api.so`: it zeroes `this+16` up front,
  then — after the boost `shared_ptr` copy-construction bookkeeping — writes the *real* raw
  `Clonk*` extracted from the constructor's `shared_ptr<Clonk>` argument into exactly that offset.
  So the wiring mechanism itself is sound *given a valid, non-empty `shared_ptr<Clonk>`*. The bug is
  upstream of this constructor: whatever calls `new ClonkServer(theSharedPtr)` is either not being
  called at all yet, or is passing an empty pointer.
- **`LunaService::registerInterface`** (the second function `clonkPipeline` calls, after
  `openSession`) is generic LS2-category/subscription plumbing — `LSSubscriptionAdd`, string
  building, `LSMessageReply` — shared identically by `playbackPipeline` too. No `ClonkServer`/`Clonk`
  construction happens there either.
- **Dead end:** searched `mediaserver`'s full disassembly and its ELF relocation table for any
  reference at all (direct call *or* a stored function-pointer relocation) to
  `ClonkServer::ClonkServer(shared_ptr<Clonk>)` — found none, despite it showing as an imported
  (`U`) dynamic symbol `mediaserver` genuinely depends on. **Conclusion: the actual constructor call
  site hasn't been found yet — it's most likely invoked lazily, on the first real method dispatch
  to a freshly-opened category, rather than eagerly at session-open time** (which would neatly
  explain why session creation always succeeds instantly while every action call fails). Finding
  that lazy-dispatch mechanism is unfinished business, not a wrong turn.

## Part 6 — the gdb live-debugging saga (concept sound, this exact setup didn't get there)

Spent real effort making live debugging work, since it would answer the question directly instead
of more static tracing:

- **Setup works:** `gdbserver` (on-device) attached to the live `mediaserver` PID, `novacom -P -f
  2159:2159` port-forwarded it, `gdb-multiarch` (this host) connected and correctly loaded full
  symbols for every shared library including `libmedia-api.so`, using `set sysroot`/
  `set solib-search-path` pointed at the local rootfs image copy.
- **Real gotcha, learned the hard way, twice:** a `gdb -batch` script that reaches its end (normal
  completion *or* a mid-script error) **without an explicit `detach` first kills the attached
  inferior**. This happened to `mediaserver` several times tonight. Every single time, upstart's
  `respawn` stanza on its job brought it straight back up with a new PID and no manual
  intervention needed — but if you pick this up again, always put `detach` before `quit`, and don't
  be alarmed if you see a new PID.
- **Symbolic breakpoints (`break *(Namespace::Class::method(...)+offset)`) were unreliable** across
  reconnects — sometimes "No symbol table is loaded" even right after a successful `target remote` +
  `info sharedlibrary`, seemingly a timing/loading-completeness issue with this specific old
  `gdbserver` talking to a modern `gdb-multiarch`. **Fix that worked:** compute the runtime address
  by hand (`libmedia-api.so`'s runtime load base, read from `info sharedlibrary`, plus the
  link-time function offset from `nm`, plus the offset-within-function from `objdump -d`) and
  `break *0xADDRESS` directly — this reliably set the breakpoint every time (confirmed: "Breakpoint
  1 at 0x2ac24e3c" printed cleanly).
- **The real blocker: the breakpoint never actually triggers.** With the raw-address breakpoint
  confirmed set and `continue` blocking as expected, triggering `videoCaptureStart` from a separate
  `clonk_probe` run completed completely normally (`{"returnValue":false}` came straight back) —
  gdb never stopped. We *know* from `strace` that this exact code path executes every time. The
  most likely explanation: `mediaserver` is heavily multi-threaded (GLib main loops, one thread per
  LS2 category/session judging by the `FacadeSessionBroker` log lines from Part 2), and this
  ancient (~2011) `gdbserver` build likely has incomplete `PTRACE_O_TRACECLONE`/thread-enumeration
  support when driven by a modern gdb client — the LS2 dispatch for a *newly created* per-session
  category may run on a thread `gdbserver` never properly attached breakpoints to, even though the
  breakpoint's memory patch should in principle be visible process-wide.
- **Not pursued further tonight** (diminishing returns given the device was cycled through several
  kill/respawn cycles already): trying `gdbserver --multi`, checking `info threads` right after
  attach to see whether the handling thread is even visible to gdb, or attaching directly to a
  specific TID instead of the process's main PID. Any of these would be the next thing to try if
  live debugging is picked up again.
- **Resolved in Part 8, and much simpler than threading:** the breakpoint was set on the `ctx+16`
  null-check inside `videoCaptureStart` — which, per Part 8, is dead code on every real call, since
  the actual failure happens earlier via `getArguments`/`dom["args"]` returning `ok=false`, which
  skips straight past that check entirely. The breakpoint never fired because that line of code
  never runs, not because of a gdbserver/threading limitation. The gdb setup notes above (sysroot,
  raw-address breakpoints, the `detach`-before-`quit` gotcha) are still accurate and reusable if
  live debugging is needed for something else later.

**Device state, verified clean at the end of this session:** `mediaserver` running normally and
stable (same PID since the last respawn, uptime ~100 minutes with no further reboots),
`imlibpurpletransport` (messaging) confirmed healthy, `gdbserver` killed, no port forwards left
open, `clonk_probe` deployed and role-registered, currently built to test `videoCaptureStart`.
Nothing left running that shouldn't be.

**One incident along the way, for the record:** early in this session, restarting `ls-hubd_private`
(to load a new LS2 role file) went wrong — its upstart job script doesn't `exec` into `ls-hubd`, so
upstart tracked the wrapper shell instead of the real daemon; the orphaned real daemon kept running
with stale role tables, the second instance failed to bind the already-held socket and exited
non-zero, which tripped `ls-hubd_private_watchdog`'s reboot path
(`reboot_ls-hubd_if.sh` reboots on any non-zero exit outside runlevels 0/6/U). **The device
rebooted once** (confirmed via `/proc/uptime`), and recovered fully on its own — `mediaserver`,
`ls-hubd`, and messaging all came back up normally, all files survived (persistent storage, not
`/tmp`). Net effect: harmless, and it happened to load the role file we needed anyway.

## Next session: the plan to actually hook up WhatsApp video

**1. DONE (Part 8) — `videoCaptureStart` AND `videoPlayerStart` both confirmed working live**, in
the same session, with clean start/stop cycles on both sides. Root cause was the payload shape
(`{"args":[...]}`, not a bare array), not a construction bug. `videoPlayerActive` reads back `true`
after start (further along than capture, where `videoCaptureActive` stays `false` — not chased
further, not a blocker).

**2. The Phone app / UI side needs no further research** (Part 4) — implement directly against the
confirmed contract:
   - `glue/call.c` implements a new `changeMedia(id, outgoingVideo, incomingVideo)` LS2 method.
   - `callStateQuery` responses gain `videoURI` (top-level), `outgoingVideo`/`incomingVideo`
     (per-line), `incomingVideoState` (per-line, `"unavailable"|"available"|"streaming"`).
   - `videoURI` is the clonk session's own `palm://com.palm.mediad.Clonk_NNNN/` LS2 URI — the Phone
     app's `<Video>` tag and PiP calls (`updatePipSettings` with
     `{args:[{top_left,bottom_right,scale,orientation}]}`) both target it directly, no further
     plumbing needed on our side once we hand over the right URI.

**3. Capture → WhatsApp send** (#1 now unblocked): `glue/call.c` opens a `clonk` session on
   answer/dial-with-video, sets `deviceUri`/`videoBitrate`/`h264SenderConstraints` to something
   ≤320p (matching the `webos-vc` history's hard-won constraint — the *other*, newer gst-omx stack
   on this device aborts above 320p; `palmvideoencoder`, found in Part 3, may be a more reliable
   encode path than the gst-omx one), calls `videoCaptureStart({"args":[w,h,fps,bitrate]})`, then attaches
   to the **frame data-plane, confirmed via static analysis to be System V shared memory** (not LS2
   messages, not a pipe — `mediaserver` logs `"Issuing Video Frame Capture message. shared mem
   name=%s,size=%d,ptr=%p,shmMemId=%d"`, and `VideoSink::createShmMemName()` derives the segment
   name per session). The exact triggering LS2 message/event that hands over the `shmMemId` is the
   next thing to pin down once capture itself actually starts.

**4. WhatsApp receive → playback:** symmetric — feed access units from `Call.ReceiveVideo` into
   `videoPlayerStart({"args":[w,h]})`'s decode/render path (confirmed working, #1), which almost
   certainly hands back decoded frames the same shared-memory way, rendered automatically once
   `videoURI` is wired per #2.

`clonk_probe` (built, deployed, role-registered) is immediately ready to test whatever comes out
of #1 — the payload conventions for every method involved are now known exactly, so any fix to the
construction bug should be testable within one build/deploy/run cycle.

## Part 7 — #2 implemented and compiling clean for the real target

While still chasing #1 (searched mediaserver/libmedia-api.so for a `dlopen`-loaded plugin that
might be the real `Clonk` factory implementation — a plausible link to `skype-disable`'s indirect
effects; found nothing, only the standard statically-`NEEDED` libraries, so that specific theory is
weaker now, not stronger), implemented the whole Phone-app integration contract from Part 4 for
real, in parallel:

- **`call.go`**: `callInfo` gained `incomingVideoState`. `wireCall` now initializes it from
  `mcCall.IsVideo()` and wires `mcCall.OnVideoState(...)` to keep it live
  (`"streaming"`/`"available"`/`"unavailable"`, tracking the *peer's* video independent of whether
  our own capture/render pipeline works). `emitCallState` includes it in the JSON. New
  `//export gowhatsapp_go_call_changemedia(id, hasOutgoing, outgoing, hasIncoming, incoming)`
  implements the real toggle logic: `StartVideo()` for a fresh audio→video upgrade,
  `SetVideoEnabled()` to mute/unmute an already-video call — reusing meowcaller's existing,
  already-validated (Part 1) video signaling API, not anything new or unproven.
- **`glue/call.c`**: `changeMedia` is wired to a real handler (`m_changemedia`, replacing the
  `m_ok` stub), parsing the "field absent = leave as-is" convention `VideoCall.js` actually uses.
  Added clonk session lifecycle management: `gowhatsapp_call_video_active(int on)` (called from Go
  on any video-state flip) opens a `palm://com.palm.mediad/service/clonk` session via
  `LSCallOneReply` and captures its `location` into `g_clonk_uri`; `push_callstate` now splices
  that real URI into Go's `"videoURI":""` placeholder before forwarding to `callStateQuery`
  subscribers (`inject_video_uri` — Go owns call-state structure, C owns the session and its URI).
  No confirmed explicit teardown call exists yet (see Part 5), so `clonk_close()` just drops the
  local reference for now — safe, since session creation itself has no observed side effect beyond
  the session existing.
- **Builds clean for the real target**: ran the actual `build-combined.sh` (Go c-archive → C glue →
  final `.so` link) end to end. Needed one `go mod tidy` first in `purple-combined` itself (its
  go.mod `replace`s `meowcaller` with the local `./third_party/meowcaller` directory I'd already
  modified — bumping meowcaller's own dependencies meant the parent needed reconciling too).
  Produced `build-arm/libwhatsmeow.so` (29.5 MB unstripped), all `NEEDED` libs resolved correctly,
  `purple_init_plugin` present. Confirmed via `nm -D` that both new symbols
  (`gowhatsapp_call_video_active`, `gowhatsapp_go_call_changemedia`) and their cgo trampolines are
  actually present in the linked binary — not just "other things compiled," the new wiring itself
  linked correctly.

**What this gets you today, independent of the still-open native bug:** video call negotiation
(offer/accept/upgrade), toggling your own outgoing video on/off mid-call, and tracking the peer's
video state — all genuinely functional, because they only touch meowcaller's already-validated
WhatsApp-signaling layer (Part 1). Clonk session creation (and therefore a real, live `videoURI`
being handed to the Phone app's `<Video>` tag) also works today. What doesn't work yet: actual
frames flowing — that's still gated on Part 5's construction bug.

**Not yet done:** this hasn't been deployed to the device. Unlike `clonk_probe` (a standalone,
role-scoped test binary that never touched anything live), this *is* the real WhatsApp/Facebook
messaging plugin — deploying it means swapping `libwhatsmeow.so` under the account's live
messaging session, a materially bigger blast radius than anything else tonight. Needs the
account's own explicit go-ahead before doing that, and ideally review of the diff first.

## Part 8 — the real root cause: payload shape, not object construction (corrected)

Parts 5/6 chased a dead end: a hypothesis that `ClonkServer`'s `shared_ptr<Clonk>` business object
was never validly constructed at runtime, based on a `videoCaptureStart` disassembly read that only
covered its first ~150 instructions and a null-check that looked plausible in isolation. Two things
that should have been red flags earlier, in hindsight: property getters (`getDeviceUri`, etc.)
always worked fine against real sessions — meaning *some* backing object clearly existed — and the
gdb breakpoint on that null-check never fired despite `strace` proving the code path executed.

**Finding the real cause required reading the *whole* function, not just the first branch.** Full
disassembly of `ClonkServer::videoCaptureStart` (`libmedia-api.so` 0xbb0cc–0xbb58c) shows:

- `ctx+16` (a `shared_ptr<media::Clonk>`) being null hits `__assert_fail`, not a silent return — so
  if it were ever actually null, `mediaserver` would abort. It never has, across dozens of test
  runs. That alone rules out the Part 5 theory.
- The function's actual logic: unmarshal up to 4 args by indexing a JValue named `args` at
  positions 0–3 (`JValue::operator[](int)`), then make a real virtual call through `ctx+16`'s vtable
  at offset `0xd8` (the actual capture-start implementation), then a second vtable call at offset
  `0x8` that acts as a success/failure check, and — only on failure — a third vtable call at offset
  `0xc` (looks like `getLastError()`) to build an error-message string for the reply.
- The args only get unmarshalled at all if an internal `ok` flag (set by `getArguments()`) is true.
  If it's false, the function jumps straight past all argument handling and the real vtable calls,
  straight to building `{"returnValue":false}` with an **empty** message string — exactly what we'd
  been observing.

**Tracing `getArguments` itself** (`media::luna::LunaInterface::getArguments(LSMessage*, char
const*, bool&)`, `libmedia-api.so` 0x74568) found the actual gate:

```
JDomParser::parse(payload, schema, ...)      // succeeds on any valid JSON, incl. a bare array
  -> if parse failed: ok = false, return {}
dom["args"]                                   // JValue::operator[](const string&) — string-keyed!
  -> if !isArray(): ok = false, return {}     // <-- this is what actually failed
  -> else: return dom["args"], ok = true
```

The second parameter to `getArguments` (which earlier disassembly passes had assumed was a schema
key) is a `__PRETTY_FUNCTION__`-style diagnostic string (confirmed by reading the actual bytes at
its computed `.rodata` address: `"static bool media::luna::ClonkServer::videoCaptureStart(LSHandle*,
LSMessage*, void*)"`) — used only for logging, not validation. The real gate is the literal string
`"args"` (`.rodata` 0x153f5c, confirmed by reading the bytes directly), used as a JSON object key.

**A bare top-level array like `[320,240,15,400000]` parses as valid JSON, so `getArguments` doesn't
fail at the parse step — but `dom["args"]` on a top-level *array* value doesn't return an array (or
anything usable), fails `isArray()`, and `ok` gets set false.** This is a silent, textless failure
that looks identical to a "the object doesn't exist" bug from the outside — which is exactly what
sent Part 5 down the wrong path. The real convention every `clonk` action method uses is an object
wrapper: **`{"args":[...]}`**.

**Fixed and confirmed live** (`clonk_probe`, rebuilt/redeployed):

```
>>> videoCaptureStart {"args":[320,240,15,400000]}
<<< {"returnValue":true}
>>> getVideoCaptureHasPipeline {}
<<< {"propertyRead":{"name":"videoCaptureHasPipeline","value":true},"returnValue":true}
>>> videoCaptureStop {"args":[]}
<<< {"returnValue":true}
```

`/var/log/messages` for the same window confirms real pipeline construction, not just a "true"
reply: `mediaserver` logs the session going active (`PowerMediaService::okToSuspend: Denied:
'com.palm.mediad.Clonk_NNNNN' is active`, a `POWERD-ACTIVITY` wake-lock for ~10.5s), and on
teardown, `media-pipeline: virtual media::pipeline::ManagedClonkPipeline::~ManagedClonkPipeline()
pipeline not suspended` — a real `ManagedClonkPipeline` object existed and was torn down without a
graceful suspend step (expected, since `clonk_probe` just exits rather than driving a full
suspend/resume sequence — this fires even after a successful `videoCaptureStop`, so it reflects the
probe's abrupt disconnect, not a stop failure).

`getVideoCaptureActive` still read `false` 3 seconds after start in this test — plausibly because
"active" only flips once the camera/OMX pipeline actually reaches a running state and starts
producing frames, which may need more time, or a peer/consumer attached via the shared-memory
handoff (Part 3) before it flips. Not chased further for capture, but see below — the player side
gives a strong clue that this is specific to capture, not a general problem.

**`videoPlayerStart` retested immediately after, same fix, same session — also confirmed working,
and further along than capture:**

```
>>> videoPlayerStart {"args":[320,240]}
<<< {"returnValue":true}
>>> getVideoPlayerActive {}
<<< {"propertyRead":{"name":"videoPlayerActive","value":true},"returnValue":true}
>>> getVideoPlayerHasPipeline {}
<<< {"propertyRead":{"name":"videoPlayerHasPipeline","value":true},"returnValue":true}
>>> videoPlayerStop {"args":[]}
<<< {"returnValue":true}
```

Unlike capture, `videoPlayerActive` reads back **`true`** (not just `HasPipeline`) — the player side
reports itself fully active, not just constructed. And this run's session teardown in
`/var/log/messages` shows a clean `Stopping session ...` with **no** `ManagedClonkPipeline ...
pipeline not suspended` warning — meaning both `videoCaptureStop` and `videoPlayerStop` left the
pipeline properly suspended this time (the warning in the first test run came from a probe version
that still sent the stop calls with the wrong shape). Confirms the `{"args":[...]}` fix's start
*and* stop calls both work correctly, for both directions, in a single session — the architecture
Part 2 described (one `clonk` session per call, driving capture and playback together) checks out.

No corresponding `dmesg`/kernel-level camera or `/dev/video*` activity was observed for either
direction — consistent with the capture-side finding in Part 3 that hardware engagement is a later
step than pipeline construction, not evidence against this working; the LS2/GStreamer-object layer
being fully confirmed is what actually mattered here.

**Practical implication for `glue/call.c`'s clonk wiring (Part 7):** any future direct-LS2-call code
for `videoCaptureStart`/`videoPlayerStart`/`setDeviceUri`/etc. (not yet added — Part 7 only opens
the bare session so far) must use the `{"args":[...]}` wrapper, not a bare array. `clonk_probe.c`'s
current sequence (create session → getDeviceUri → setDeviceUri → videoCaptureStart → status →
videoCaptureStop → videoPlayerStart → status → videoPlayerStop → quit) is a working reference for
the exact shape of every one of these calls.

**Next:** find the actual shared-memory (`shmMemId`) handoff trigger for frame transfer now that
both session setup and both start/stop directions are confirmed working end to end.

## Part 9 — chasing the shmMemId handoff: found the shm mechanism, but `mediaserver` looks like it does full RTP transport internally

Went looking for the trigger that hands the `shmMemId` from `"%s: Issuing Video Frame Capture
message. shared mem name=%s,size=%d,ptr=%p,shmMemId=%d"` (the log line Part 3 originally found and
assumed was the frame data-plane) to an external client. Found a lot — and it changes the picture.

**Decoded the object layout by reading `g_log`'s varargs against the format string.** The function
that logs this, `media::pipeline::gst::element::VideoSink::captureVideoFrame()` (`mediaserver`
0xe8150, statically linked, symbols intact), passes its varargs in AAPCS order (r3, then stack):
`this+16` = shm name (`std::string`), `this+20` = `shmMemId` (`int`), `this+28` = mapped `ptr`,
`this+120` = `size`. It only proceeds if `shmMemId >= 0` and `ptr != NULL` — i.e. it *uses* an
already-set-up segment, it doesn't create one.

**Traced segment creation to `VideoSink::createShmMemName(std::string)`** (`mediaserver` 0xe83a0):
builds the name as a fixed rodata prefix, `"/videocapture_"` (`.rodata` 0x1179d8), concatenated
with whatever `std::string` the `VideoSink` constructor was given. Traced the constructor's actual
callers and found the argument is *also* a fixed rodata literal, not anything session-specific:
`ClonkPipeline::initializeVPlayPipeline` passes `"clonk-remote-video"` (`.rodata` 0x108dac),
`ClonkPipeline::initializeVCapturePipeline`'s corresponding branch passes `"clonk-preview"`
(`.rodata` 0x108f3c). So in principle the shm names are fixed, well-known constants — no per-session
handoff would even be needed for the *name*.

**But the actual SysV key isn't derived from that name at all.** Traced the `shmget()` call itself
(`mediaserver` imports real `shmget`/`shmat`/`shmctl`, not `shm_open`/`ftok`): `shmget(key=(int)this,
size=this+120, flags=IPC_CREAT|0600)` — **the key is the `VideoSink` C++ object's own heap pointer**,
cast straight to an int. That's a private, per-run heap address inside `mediaserver`'s address space
— unpredictable and uncomputable by any external process. If this is really the data plane, some
LS2 message *must* carry the resulting `shmid` out to a client; nothing in `ClonkServer`'s ~50
registered LS2 methods does (see below), which was the first sign this isn't the actual mechanism
in play here.

**Checked live, empirically: no shm segment appears at all during a real session.** Baseline
`/proc/sysvipc/shm` before any test, then polled it at t=4s/8s/12s through a full
`clonk_probe` run (capture start→status→stop, player start→status→stop) — zero segments ever
attributed to `mediaserver`'s pid (2619), the whole way through. Two explanations, not mutually
exclusive: (a) `VideoSink` construction in the capture path is gated behind a conditional
(`mediaserver` 0xb61e0, a vtable call through a `this+4` helper object) that looks like a
hardware-overlay-available check — plausible that real hardware overlay is what's actually in use,
bypassing this class entirely; (b) the player-side `VideoSink` construction (`ClonkPipeline
::initializeVPlayPipeline`, confirmed *not* gated behind anything unusual — its neighboring branch
is just the generic `gst_element_factory_make` failure check every element in this function has) is
most likely gated on the decoder producing a first output pad (`PlayerPipeline
::newDecodedPadCallback` is a literal GStreamer dynamic-pad-added callback that also constructs a
`VideoSink`) — meaning it never fires because `clonk_probe` starts the pipeline but never pushes any
real H.264 bytes into it. (b) is the more likely explanation for the player side specifically, and
doesn't rule the mechanism out — just means it needs real data flowing to observe.

**The bigger finding: `ClonkServer`'s full registered LS2 surface (dumped via `nm -C -D`, ~50
methods/properties) has no frame/shm/buffer-related getter at all**, but it does have
`H264SenderConstraints`, `H264SenderParameters`, `H264ReceiverParameters`, and — tellingly —
`test_GenerateCapturePcap` / `test_GenerateReceivePcap`. Disassembled the marshalling code for both
structs directly (reading the `pbnjson::JValue` key strings the same way Part 8 decoded
`getArguments`'s `"args"` key):

- `H264SenderParameters` = `{profile_idc, profile_iop, level_idc}`
- `H264SenderConstraints` = `{profile_idc, profile_iop, level_idc, max_mbps, max_fs, max_cpb,
  max_dpb, max_br, max_smbps, redundant_pic_cap}`

**These are the literal RFC 6184 (H.264-over-RTP) SDP `fmtp` parameter names** — `max-mbps`,
`max-fs`, `max-cpb`, `max-dpb`, `max-br`, `max-smbps`, `redundant-pic-cap` are exactly the profile/
level negotiation fields exchanged in a real SDP offer/answer for H.264 video. Combined with the
PCAP test hooks (which only make sense if the pipeline is generating real RTP/UDP traffic to
capture), this is strong evidence that **`ClonkPipeline` does full H.264 encode → RTP payload →
network send (and the receive-side mirror) *inside* `mediaserver` itself** — the same
self-contained-media-engine architecture Part 2's original research assumed for Skype, now backed
by concrete evidence from the actual negotiation-parameter names, not just precedent.

**What this means for the plan (supersedes the shm-handoff framing from Part 3/Next-session):** if
`mediaserver` owns the real RTP transport end to end, there is no raw-frame handoff to intercept for
WhatsApp integration — the shm/`VideoSink` mechanism traced above is most plausibly for *local
display/PIP rendering* only (both the local camera self-view and the decoded remote party's video),
not for exporting frames to a third-party encoder. The actual integration point would instead be
**wherever `ClonkPipeline` sends/expects its RTP packets** — i.e. we'd need `mediaserver`'s outgoing
RTP aimed at a local relay we control (and its incoming RTP fed from one), then bridge that to
meowcaller's `SendVideo`/`ReceiveVideo` (NAL-unit level, not RTP — meowcaller handles WhatsApp's own
RTP/SRTP framing internally, so the bridge only needs to move raw H.264 access units across).

**Not yet found: how that RTP destination/source gets configured.** None of `ClonkServer`'s ~50 LS2
methods expose anything address/port/socket-like — no `remoteUri`, no `rtpUri`, nothing in that
family. Candidates for next session, not yet checked: an fd handed over via LS2's underlying
Unix-domain-socket connection (`SCM_RIGHTS`), a fixed/hardcoded loopback port convention, or
something baked into pipeline construction (`ClonkSession`/`ClonkPipeline` construction args) that
isn't LS2-visible at all. This is now the more fundamental open question than the shm handoff this
part set out to find — worth treating as the real "next session" item.

## Part 10 — found it: `libpalmgstskype.so` is a real, embedded copy of Skype's own SkypeKit SDK,
## and the transport is two fixed-name abstract Unix domain sockets

Followed Part 9's open question ("how does the RTP destination get configured") by going back to the
actual GStreamer element chain instead of the LS2 property surface — and it resolves cleanly.

**Decoded every `gst_element_factory_make()` call in both `ClonkPipeline::initializeVCapturePipeline`
and `initializeVPlayPipeline`** (same movw/movt address-resolution technique used throughout this
investigation, applied systematically this time — see the pipelines below). This reveals the real
element chains, which neither Part 3 nor Part 9 had fully mapped:

- **Capture (send) pipeline:** `camsrc` ("Camera Source") → `capsfilter` ("Resolution Caps Filter")
  → `tee` ("Camera Tee") splitting into a `queue` → `fakesink`/local-preview branch and a
  `queue` → `palmvideoencoder` ("Palm Video Encoder", the real hardware H.264 encoder Part 3 first
  found) → `queue` → **`skypevideosink`** ("clonkvhsink" — "vh" = VideoHost).
- **Playback (receive) pipeline:** **`skypevideosrc`** ("clonkvhsrc") → `palmvideodecoder`
  (confirmed-working hardware decoder) → `queue` → (display sink).

**`skypevideosrc`/`skypevideosink` are the real boundary — not the shm-based `VideoSink` class Part 9
chased.** Both are custom GStreamer elements registered by `libpalmgstskype.so`. Their C++ backing
class, `GstSkypeInstance`, has `SendRTP(void*, unsigned int)` (outgoing) which — *if* a `VideoHost*`
is registered at `this+8` (silent no-op otherwise, `bxeq lr`) — forwards straight to
**`VideoHost::SendRTP`**, a real, concrete (not abstract) implementation living in the same `.so`.

**`libpalmgstskype.so` turns out to contain a literal embedded copy of Skype's own SkypeKit SDK.**
`nm -C -D` on it turns up an entire `Sid::` namespace (`Sid::Protocol::BinClient`/`BinServer`,
`Sid::CommandInitiator`, `Sid::TransportInterface`, `Sid::UnixSocket`, `Sid::AVTransportWrapper`,
`SkypeVideoRTPInterface`/`SkypeVideoRTPInterfaceCb`, `SEBinary`/`SEString`/`SEIntList` — all classic
SkypeKit SDK type names), and `strings` turns up the literal source path
`Inc/skypekit/ipc/cpp/AVTransport/SocketTransport.cpp`. `VideoHost::SetCallback(SkypeVideoRTPInterfaceCb*)`
stores the callback at `this+12`; `VideoHost::SendRTP` calls through it. The concrete implementation of
that callback here is `Sid::SkypeVideoRTPInterfaceCbClient::SendRTPPacket(SEBinary const&)` — an RPC
*client stub* (disassembled directly) that just wraps the bytes and calls
`Sid::Protocol::BinClient::wr_call_lst(...)` — i.e. it serializes the RTP packet with SkypeKit's own
binary RPC protocol and writes it out over a transport object, it does not touch the bytes itself.

**Traced the transport to `Sid::UnixSocket`, confirmed via `MakeAddress`'s address-construction code:**
it writes `sun_family=AF_UNIX` (`strh` of `1`), a zero byte at `sun_path[0]`, then `strcpy`s the given
name starting at `sun_path[1]` — the standard Linux **abstract-namespace** Unix domain socket
convention (no filesystem entry, name only visible via `/proc/net/unix` with a leading `@`).
`Sid::UnixSocket::Connect(char const*, bool isServer, int timeout)` dispatches to either
`ClientConnect()` (retries in a sleep/retry loop, i.e. waits for a server to appear) or
`ServerConnect(timeout)` depending on the `isServer` flag — so this same code can run either role.

**Found the actual socket names as plain strings in the binary:**
```
/tmp/vidrtp_to_skypekit_key
/tmp/vidrtp_from_skypekit_key
/tmp/pcm_to_skypekit_key
/tmp/pcm_from_skypekit_key
```
(used as abstract-namespace names, not real files — despite looking like filesystem paths, per the
`MakeAddress` NUL-prefix construction above). Video RTP and audio PCM each get their own pair of
fixed, well-known socket names, one per direction.

**What this means for WhatsApp integration:** this is not a raw-frame shm handoff (Part 9's original
target) and not a fully-internal RTP stack (Part 9's revised theory) — it's a **well-known, fixed-name
IPC boundary designed from the start for an external process to plug into**, exactly matching
SkypeKit's real-world architecture (the actual `skypekit` engine binary was always meant to be a
separate process from whatever hosts the media I/O). That's *good* news for feasibility: this is the
literal mechanism `skypekit` itself would have used, not something webOS-specific we'd be
reverse-engineering blind. A relay component that opens `vidrtp_to_skypekit_key` (as whichever role
mediaserver expects the peer to take) could, in principle, receive/inject RTP packets and bridge them
to meowcaller's `SendVideo`/`ReceiveVideo` (NAL-unit level — the RTP depacketization would need to
happen in our own relay, since meowcaller doesn't speak this SkypeKit wire format).

**Confirmed the client/server role for each socket** by disassembling `GstSkypeInstance::RunVideoHost()`
in full (`libpalmgstskype.so` 0x29bc0), which sets up *two separate* transport objects, one per
direction:

- **`/tmp/vidrtp_from_skypekit_key`** — `mediaserver` calls `Sid::AVServer::Connect(path, 10000)` —
  **`mediaserver` is the SERVER here: it listens**, with a 10-second setup timeout. This transport is
  wrapped in a `Sid::Protocol::BinServer`, which dispatches *incoming* RPC calls via `ProcessCall`
  (matches `Sid::SkypeVideoRTPInterfaceServer::ProcessCall` found in Part 10) — i.e. this channel is
  for the remote peer to **push incoming RTP packets into** `mediaserver`'s playback/decode pipeline.
- **`/tmp/vidrtp_to_skypekit_key`** — `mediaserver` calls `Sid::AVTransportWrapper::Connect(path,
  isServer=false, 500)` — **`mediaserver` is the CLIENT here: it dials out**, retrying in a sleep loop
  for up to ~50s (500 × the observed 100ms retry interval) waiting for something to be listening. This
  transport is wrapped in a `Sid::Protocol::BinClient`, which *issues* outgoing RPC calls via
  `wr_call_lst` (matches `Sid::SkypeVideoRTPInterfaceCbClient::SendRTPPacket` from Part 10) — i.e.
  this channel is for `mediaserver` to **push its own encoded capture RTP packets out**.

Both string addresses were confirmed by resolving the exact literal-pool words feeding each `Connect`
call site (same PC-relative address-resolution technique used throughout this investigation) —
not assumed from the socket names alone.

**Concretely, for a WhatsApp bridge:**
- **Outgoing (WhatsApp send):** run a small server that binds the abstract-namespace socket
  `vidrtp_to_skypekit_key`. `mediaserver` connects to it after `videoCaptureStart` and pushes encoded
  RTP packets via SkypeKit's `BinClient` wire calls; the bridge decodes those calls, extracts the RTP/
  H.264 bytes, and feeds them to meowcaller's `Call.SendVideo`.
- **Incoming (WhatsApp receive):** run a small client that connects to `vidrtp_from_skypekit_key`
  after `videoPlayerStart` (mediaserver is listening, server role). The bridge takes NAL units from
  meowcaller's `Call.ReceiveVideo`, wraps them as RTP, and issues them as `BinServer`-style RPC calls
  into `mediaserver` to feed the playback/decode pipeline.

**Not yet done at the time Part 10 was written:** reverse-engineer enough of `Sid::Protocol::BinCommon`'s
wire format to write a minimal standalone test tool. Web search (Part 11) confirmed the SkypeKit SDK
isn't available as a public/leaked source archive — it's a real but discontinued (~2014) paid/licensed
product, so no shortcut there. The empirical approach (build a tool that binds the real socket and
captures real bytes) turned out to be blocked by something more fundamental — see Part 11.

## Part 11 — the wire-protocol work was premature: the GStreamer pipelines never actually reach a
## linked, running state, and the real blocker is caps/resolution configuration, not the SkypeKit
## socket layer

Built `vidrtp_sniffer.c` (this directory) to get ground truth instead of guessing `Sid::Protocol`'s
byte format from disassembly alone: it binds `/tmp/vidrtp_to_skypekit_key` using the *exact* same
abstract-namespace construction `Sid::UnixSocket::MakeAddress`/`ServerConnect` use (full 110-byte
zero-padded `sockaddr_un`, matching the fixed `addrlen=110` both `bind()` and `connect()` use on this
target — a shorter, strlen-derived addrlen would silently create a different abstract name and never
match), then accepts and hex-dumps whatever `mediaserver` sends.

**First finding, fixable, harmless build bug:** the tool initially failed to run at all —
`clock_gettime@GLIBC_2.17` isn't present on this device's much older libc, even though
`clock_gettime()` itself is ancient; swapped to `time()` (confirmed via `readelf -V`, now needs only
`GLIBC_2.4`, matching `clonk_probe`). Not a build-script bug — `build-vidrtp-sniffer.sh` was just
missing nothing conceptually wrong, the toolchain's *default* sysroot libc is far newer than the
device's; `build-clonk-probe.sh` avoids this by linking real LS2/glib libraries that happen to only
pull old symbol versions naturally. Worth remembering for any future standalone (non-LS2) tool built
with this toolchain.

**The real finding: `mediaserver` never connected to our listening socket, in two full test runs.**
Confirmed the bind itself was correct (`/proc/net/unix` showed `@vidrtp_to_skypekit_key` present,
right name, right process) — `mediaserver` simply never attempted the connection, despite
`videoCaptureStart` reporting `{"returnValue":true}` and `getVideoCaptureHasPipeline` reading `true`
per Part 8. `/var/log/messages` showed zero `RunVideoHost`/SkypeKit-related log lines during the test
window at all — the code path never even entered `GstSkypeInstance::RunVideoHost()`, let alone reached
its `AVTransportWrapper::Connect` call.

**Root-caused with the same technique Part 3 used originally: stop the upstart-managed `mediaserver`,
run it manually with `--gst-debug=4`, redirect to a file, restart upstart's copy afterward** (the
exact "for the record" procedure Part 3 documented — repeated here without incident, `mediaserver`
restored cleanly via `start mediaserver` and confirmed healthy with a quick `luna-send` sanity call
afterward). Two distinct, concrete GStreamer-level problems found this way, on the capture (send) and
player (receive) sides respectively:

1. **Capture side — fixed.** `ClonkPipeline.cpp:1262:busMsg_ERROR: Received error from plugin ...
   name Camera Source: Could not negotiate format, gstbasesrc.c(2823): gst_base_src_start()`. Queried
   `camsrc`'s actual pad template directly (`gst-inspect-0.10 camsrc`, present on-device): it offers
   **exactly three fixed caps, all locked to `framerate=30/1`** — `640x480`, `320x240`, `160x128`,
   format `NV12`. `clonk_probe` had been requesting `framerate=15` (an arbitrary early guess, never
   revisited once the `{"args":[...]}` fix started returning `true`) — not a valid combination at all,
   just silently rejected downstream at the GStreamer caps-negotiation layer, which is invisible from
   the LS2 side (`videoCaptureStart` still returns `true` because pipeline *construction* succeeds;
   only actually *starting* the source fails). Fixed `clonk_probe.c` to request `framerate=30`;
   re-ran against the same manually-debugged `mediaserver` instance and the caps error is gone —
   clean pipeline teardown at session end instead of an error message.
2. **Player side — found, not yet fixed.** `gstskypevideosrc.c:411:gst_skype_video_src_change_state:
   <clonkvhsrc> resolution not set on capsfilter` (a `WARN`-level message inside
   `libpalmgstskype.so`'s SkypeKit-derived code, not `ClonkPipeline` itself). Disassembled the exact
   call site: the warning fires when a value dereferenced from a GOT-relative (i.e. process-global,
   not per-instance) location is `<= 1`, gated behind `cmp r1, #1; bls <skip-warning>` — reads as a
   counter or two-flag combination tracking whether both width *and* height have been delivered via
   `VideoHost::SetIntProperty(propId, camid, value)` (a real, exported method — Part 10) before the
   state change. `videoPlayerStart({"args":[320,240]})`'s own width/height arguments evidently don't
   (yet confirmed) end up calling that property setter, or don't call it in time. Directly visible
   consequence: `clonkvhsrc`'s internal `rtp` child element is **never linked** —
   `gst_bin.c:1967:update_degree:<clonkvhsrc> element rtp not linked on any sinkpads` repeats for the
   whole session — so nothing can flow through it regardless of the SkypeKit socket layer.
   The capture side shows the *same symptom* (`clonkvhsink`'s internal `rtp` child, and the sibling
   `VideoHost H264 Queue`, also both permanently "not linked on any sinkpads") without an equally
   explicit warning — plausibly the same underlying cause (missing property configuration on the
   SkypeKit element), not yet confirmed to be identical.

**Practical upshot:** the `Sid::Protocol` wire-format reverse-engineering from Part 10 was the right
next question in principle, but premature in practice — there is currently no real RTP traffic on
either `vidrtp_*_skypekit_key` socket to capture, because neither `skypevideosrc` nor `skypevideosink`
ever finishes internal setup regardless of the socket layer. **The actual next blocker to resolve is
getting `clonkvhsrc`/`clonkvhsink`'s internal `rtp` element to link** — almost certainly by finding
and calling whatever `VideoHost::SetIntProperty`-driving code path is supposed to fire from
`videoPlayerStart`/`videoCaptureStart` (or an additional call we're missing, e.g. explicitly setting
`H264ReceiverParameters`/`H264SenderConstraints` — both real, separately-settable LS2 properties per
Part 10's method list — before starting). Once that's resolved and `RunVideoHost` actually starts
(confirmable live via the same `--gst-debug=4` technique, watching for
`GstSkypeInstance::RunVideoHost` log lines and an actual connection landing on `vidrtp_sniffer`), the
`Sid::Protocol` wire-format work from Part 10 becomes the correct next step again.

**Device state, verified clean at the end of this investigation:** the manually-started `mediaserver`
(PID from the `--gst-debug=4` run) was killed and the normal upstart-managed instance restored via
`start mediaserver`; a `luna-send` clonk-session-creation sanity call confirmed it works normally
afterward. No `vidrtp_sniffer` processes left running.

## Part 12 — resolved: "resolution not set" doesn't block anything, and real connectivity to
## mediaserver's SkypeKit socket is now proven live

Picked up exactly where Part 11 left off — chasing whether the "resolution not set on capsfilter"
warning genuinely blocks `RunVideoHost()`/the SkypeKit socket setup, or whether it just needed more
time than the ~3s test window Part 11 used.

**Traced the actual settings-plumbing chain first** (before the empirical test), since disassembly
suggested a possible ordering bug: `ClonkSession::videoPlayerStart(w,h)` (mediaserver 0x6e880) posts
a `ClonkHostEvent(VIDEO_PLAYER_START)` carrying `w,h`. Its handler in `ClonkSession::processHostEvent`
(0x6f530) lazily calls `ClonkPipeline::initializeVPlayPipeline()` (building `clonkvhsrc` et al) if the
pipeline isn't ready yet, **before** building a `VideoSettings{w,h}` and calling
`AbstractClonk::setVideoPlaybackSettings()`. Traced that call through `ClonkState::setVideoPlaybackSettings`
(`libmedia-api.so` 0x78730): it's a pure cache-and-notify (`notifyvideoPlaybackSettings()` fires an
LS2-subscriber-style change notification) — it never touches GStreamer. Checked `initializeVPlayPipeline`'s
own 3 `g_object_set` calls directly: none of them touch width/height either (they configure the H.264
decoder's `pictureorder`/`framepacking`, and a `test_GenerateReceivePcap`-gated `outfile` property on
what's almost certainly `clonkvhsrc`).

**Tested an ordering-fix workaround (`videoPlayerStart` → `videoPlayerStop` → `videoPlayerStart` again,
hoping the second lazy-construction would happen after `ClonkState`'s cache was already populated) —
disproved it empirically.** `--gst-debug=4` showed `clonkvhsrc` gets freshly rebuilt each pass
(`gst_element_factory_create` firing twice, once per `videoPlayerStart` call), but the "resolution not
set" warning fired on *both* passes regardless. This ruled out the ordering-bug theory as the actual
blocker (or at least, ruled out this specific workaround for it).

**Tested the "it just needs more time" theory directly — confirmed correct.** Extended `clonk_probe`'s
wait after `videoPlayerStart` from 3s to 25s and polled `/proc/net/unix` throughout: `@/tmp/vidrtp_from_skypekit_key`
appeared and stayed present through the whole window. **The "resolution not set" warning does not block
`RunVideoHost()`/the SkypeKit socket setup at all** — Part 11's concern here was unfounded; it just
needed longer than a few seconds to reach that point (`GstSkypeInstance::RunVideoHost()` most likely
runs on its own thread with some startup latency independent of the GStreamer state-change warnings).

**Confirmed via `strace` (attached live to the real `mediaserver` PID, non-invasive) exactly how the
listening socket behaves**, since `vidrtp_sniffer` connections were still being refused even once the
name appeared: `bind()` on `/tmp/vidrtp_from_skypekit_key` happens every **exactly 10 seconds**
(matching the `AVServer::Connect(path, timeout=10000)` constant found in Part 11), and each cycle is a
real `poll([...], 1, 10000)` — a genuine, several-second-long acceptable window, not a razor-thin
instant as first feared. The gap between one socket closing and the next binding is only ~1.3ms.

**Found the actual bug blocking every connection attempt — and it was simple, not a race condition or
namespace issue.** Self-tested `vidrtp_sniffer`'s own server/client modes against each other
on-device — instant success, proving the abstract-socket address-construction code itself was correct.
Ruled out network-namespace isolation directly (`/proc/*/ns/` doesn't exist on this kernel — too old to
support namespaces at all, so that was never possible). Finally `strace`'d `vidrtp_sniffer`'s own
`connect()` call side by side with `mediaserver`'s `bind()`:
```
mediaserver: bind(34, {sa_family=AF_FILE, path=@"/tmp/vidrtp_from_skypekit_key"}, 110)
our client:  connect(3, {sa_family=AF_FILE, path=@"vidrtp_from_skypekit_key"}, 110)
```
**The leading `/tmp/` was missing from the name we were passing.** Despite being an abstract-namespace
name (no real filesystem path involved at all — confirmed repeatedly through this investigation), the
literal string used as the name is the *whole* `"/tmp/vidrtp_from_skypekit_key"`, `/tmp/` included; we'd
been passing just the `vidrtp_from_skypekit_key` suffix as `vidrtp_sniffer`'s CLI argument. An easy
mistake once deep in abstract-namespace mechanics (zero-padding, fixed `addrlen=110`, etc.) — the
simplest explanation was the right one, just easy to overlook after ruling out several more exotic
theories first.

**Fixed and confirmed live: real connectivity to `mediaserver`'s actual SkypeKit transport socket now
works.** `vidrtp_sniffer client /tmp/vidrtp_from_skypekit_key ...` connects successfully on the first
attempt, consistently, across multiple runs. Held the connection open for 16+ seconds — zero bytes
arrive unprompted, confirming `mediaserver` (playing the `Sid::Protocol::BinServer` role on this
channel, per Part 10) sits passively waiting to *read* an incoming RPC call from the connecting peer,
exactly matching the `BinServer::rd_command()`-driven architecture already traced. It does not push
anything until the peer (us, eventually) speaks first.

**Where this leaves it:** every architectural piece from Parts 9–11 is now not just theorized but
directly proven live: the camera caps fix works, `RunVideoHost`/the socket layer genuinely starts on
its own once `videoPlayerStart` has run for long enough, and a real external process can now connect
to `mediaserver`'s live SkypeKit socket. **The one remaining piece is implementing enough of
`Sid::Protocol::BinClient`'s wire framing to actually send a valid RPC call** — `mediaserver` is
proven ready and waiting to receive one. This is now a concrete, well-scoped implementation task
(not open-ended reverse-engineering): decode `BinCommon::wr_call`/`wr_parms`/the `Sid::Field` type
table's byte-level encoding (all real, named, disassemblable functions already located in Part 10),
write a minimal call (e.g. whatever the real `skypekit` engine would send first — worth checking
`Sid::SkypeVideoRTPInterfaceCbClient`'s own call sequence for the expected first message), and confirm
`mediaserver` responds or starts forwarding real RTP.

**Device state, verified clean:** `mediaserver` running normally under upstart (confirmed via a
`luna-send` sanity call after every native-side test in this part), no leftover `vidrtp_sniffer`/
`strace`/manual `mediaserver` processes.

## Part 13 — decoded the wire format's fundamentals; pivoting to linking against the real .so
## instead of hand-reconstructing bytes

Continued straight into the `Sid::Protocol::BinClient` wire-format work Part 12 set up. Real, concrete
progress, confirmed via clean disassembly (not guessed):

- **Integers are LEB128 varints** (`BinCommon::wr_value(CI*, unsigned int const&)`, 0x3ec18): 7 bits
  of payload per byte, continuation bit (0x80) set on all but the last byte — identical to Protocol
  Buffers' varint encoding. Simple, well-understood, low-risk to reimplement.
- **`SEBinary` values are `varint(length)` + raw bytes** (`BinCommon::wr_value(CI*, SEBinary const&)`,
  0x3f058) — a plain length-prefixed blob. Also simple and low-risk.
- **The call structure**: `wr_call`/`wr_call_lst` → `wr_preencoded` (writes a header, increments an
  internal sequence counter, writes a responseId varint if fields are present) → `wr_parms` →
  `wr_message`, which iterates a table of 16-byte `Field` entries. Confirmed each `Field` entry embeds
  a raw function pointer at offset 0, called directly to read/write/skip that field — a generic,
  code-generated marshalling system, not a simple type-tag switch.
- **Found `RtpPacketReceived`'s exact command ID: 20.** `VideoHost`'s vtable slot for
  `RtpPacketReceived` (`0x382c4`) sits at relocation address `0x62380` (found via `readelf -r`, since
  this shared library's vtables are populated by `R_ARM_ABS32` relocations, not raw file bytes — first
  wrong turn this part: reading the on-disk vtable words directly gave garbage until this was
  understood). Cross-referenced against `SkypeVideoRTPInterfaceServer::ProcessCall`'s 34-entry jump
  table by searching the *whole* library for any call site using vtable offset `0x58` (matching
  `0x62380`'s position) — found and confirmed at `0x3b484`, inside the branch for jump-table index 19,
  i.e. **cmdId 20**. (The naive assumption "jump-table index N ↔ vtable slot N" was wrong — verified
  the real mapping empirically instead of trusting that assumption.)
- **Found the exact `Field` table pointer for `RtpPacketReceived`'s own parameter** at that same call
  site (`0x3b460`: `ldr r2,[r6,lr]`, `lr` = `.word` at `0x3bc10`) — the *correct*, compiler-generated
  descriptor for "one `SEBinary` parameter," not an approximation borrowed from a different call.

**Found, but did not finish decoding: the command header itself is a precomputed byte blob, not a
plain `cmdId + cmdName` encoding.** Traced `wr_preencoded`'s "header write" call through to
`AVTransportWrapper`'s vtable (confirmed via `BinCommon`'s own constructor, which shows `this+8` really
is the `TransportInterface*`, not `Api*` as briefly suspected) — vtable+20 resolves to
`AVTransportWrapper::bl_write_bytes(CommandInitiator*, unsigned int count, char const* data)`, a *raw*
byte writer. `SendRTPPacket`'s call site passes a **compile-time-precomputed pointer+length** as
`(data, count)` — the entire cmdId+cmdName header for that specific call, already serialized into
`.rodata` by the SkypeKit code generator, just written raw rather than re-encoded per call. Attempted
to dump those exact bytes to reverse the header format empirically — **made a GOT-relative addressing
mistake and read the wrong location** (landed in a nearby RTTI type-name string table instead, an easy
mistake to make by hand at this depth, caught before it caused any harm since nothing was sent to the
device based on it).

**Decision: stop hand-reconstructing wire bytes, pivot to linking against the real `.so` directly.**
Given a second hand-arithmetic mistake in this same part (on top of the vtable-relocation one), and
that any further mistakes here would risk sending malformed bytes to the *live* `mediaserver` process,
the safer and more reliable path is to **cross-compile a small program that links directly against
`libpalmgstskype.so`** and calls its real, already-correct compiled functions — `AVTransportWrapper`
(construct + `Connect("/tmp/vidrtp_from_skypekit_key", isServer=false, ...)`, matching the exact role
already proven live in Part 12), `Sid::Protocol::BinClient` (construct, wrapping that transport),
`SEBinary::set(void const*, unsigned)` (confirmed exported, used by `VideoHost::SendRTP` itself), and
`BinClient::wr_call_lst` (called directly with cmdId=20, the confirmed `RtpPacketReceived` field table
pointer, and our own `SEBinary`). This reuses 100% of the real, tested wire encoding — the only thing
that needs to be correct is the C++ object layout for calling into it, not the byte format itself.

**Device state:** no device-side testing happened in this part (pure static analysis); `mediaserver`
untouched, still the normal upstart-managed instance from Part 12.

## Part 14 — built it, and it works: a real `RtpPacketReceived` RPC call successfully sent to and
## processed by mediaserver's live SkypeKit interface

Built and tested Part 13's plan (`skypekit_send_test.cpp` + `build-skypekit-send-test.sh`, this
directory). Two real bugs found and fixed via live, iterative testing — both caught safely, since
(as designed) any mistake here could only crash our own test process, never `mediaserver`:

1. **Runtime library path.** First run failed immediately: `error while loading shared libraries:
   libpalmgstskype.so: cannot open shared object file`. `-Wl,-rpath-link` (used at link time) only
   affects link-time symbol verification, not the runtime search path — the library lives in a
   GStreamer plugin directory (`/usr/lib/gstreamer-0.10/`), not the standard library path. Fixed by
   setting `LD_LIBRARY_PATH=/usr/lib/gstreamer-0.10` when running the tool (not baked into the
   binary — simplest fix for a throwaway test tool).
2. **`SEBinary`'s pre-`set()` state.** With that fixed, the tool connected successfully
   (`connected.`) and got as far as `SEBinary::set()` before segfaulting. Added a `SIGSEGV` handler
   with `sigaction(SA_SIGINFO)` directly in the test program (gdb remote debugging has been
   unreliable all session — see Part 6 — and this device's `strace` is too old to decode `siginfo`'s
   fault address) to print the fault address and registers ourselves rather than keep guessing.
   Root cause: an all-zero `SEBinary` buffer isn't valid — disassembly of `VideoHost::SendRTP`'s own
   inline construction of a temporary `SEBinary` (`libpalmgstskype.so` 0x36644-0x36664, right before
   its own `SEBinary::set()` call) shows the pre-`set()` state is `{0, 0, 0, 1}` as four words, not
   all zero — offset+12 (likely a refcount) must be `1`. Fixed by setting that one word explicitly.

**With both fixed, the tool still crashed — one more real bug, caught the same safe way.** Fault
address `0x2`, deep inside `wr_call_lst`. Reconsidered the field-table argument: Part 13 had computed
and passed an *already-offset* pointer (`M_SkypeVideoRTPInterface_fields + 91*16`) with
`fieldCount=0`. Re-examining `ProcessCall`'s own cmdId=20 dispatch site
(`libpalmgstskype.so` 0x3b448-0x3b490) more carefully: it calls `rd_parms(ci, fields=<raw base
pointer, unindexed>, count=91, buf)` — the base pointer and the index are passed as *separate*
arguments, meaning the callee computes `fields + index*16` internally rather than expecting a
pre-offset pointer from the caller. Fixed to pass the raw base pointer with `fieldCount=91` instead
— **and it worked**: `wr_call_lst` returned `0` (success), no crash, `mediaserver` confirmed fully
healthy afterward (same PID, `luna-send` sanity call succeeded).

**Confirmed via `--gst-debug=4` that the call had a real, visible effect on `mediaserver`'s internal
pipeline — not just "didn't crash."** Compared against every prior test run this session: the
`clonkvhsrc` bin's internal `rtp` sub-element (a `GstSkypeRtpSrc`, `gstskypertpsrc.c`) had *never*
shown any lifecycle activity in any earlier log capture — only the endless
`element rtp not linked on any sinkpads` message. In this run, immediately after our injected call,
that same element logs real activity: `unlock`, `unlock_stop`, `stop`, and critically
`gst_skype_rtp_src_create` actually being invoked (reporting `"wrong state (unlocked)"` — a real,
different, further-along failure mode than "never touched at all"). The linking issue isn't fully
resolved yet, but this is concrete evidence `mediaserver` genuinely received, parsed, and dispatched
our hand-constructed `RtpPacketReceived` call through to the real `VideoHost` implementation and its
GStreamer element — reproduced consistently across multiple runs, not a one-off fluke.

**Where this leaves it:** the core, hardest problem of this whole investigation — proving a real
SkypeKit RPC call can be constructed and delivered to `mediaserver` without needing the actual
SkypeKit SDK source — is solved and demonstrated live. What remains is refinement, not
architecture-level uncertainty: reverse-engineer why `gst_skype_rtp_src_create` reports "wrong state
(unlocked)" (likely a sequencing issue — probably needs the pipeline already in `PLAYING`, or a
`SetIntProperty`/resolution call first, before `RtpPacketReceived`), and separately implement the
mirror-image outgoing path (`SendRTPPacket`, cmdId confirmed as 4 back in Part 10/13's disassembly)
for the capture/send direction using the exact same technique.

**Device state, verified clean:** the manually-started `mediaserver` (`--gst-debug=4` instance) was
killed and the normal upstart-managed instance restored via `start mediaserver`; confirmed healthy
via `luna-send` afterward (same pattern used throughout this session). No leftover test processes.

## Part 15 — "wrong state (unlocked)" root-caused: it's normal `GstBaseSrc` teardown, not a bug

Part 14 left one open question: is `gst_skype_rtp_src_create`'s `"wrong state (unlocked)"` message a
real, further-along protocol/sequencing bug, or just a timing artifact of our injected call landing
too close to the fixed-duration test's own `videoPlayerStop` teardown?

**Disassembly of `gst_skype_rtp_src_create`** (`libpalmgstskype.so` 0x25474, `gstskypertpsrc.c:291`)
shows it's a standard `GstPushSrc`-derived element: it checks a flag at `this+0x1a8` (set by
`unlock()`, cleared by `unlock_stop()`) at the top of `create()`, and if set, logs exactly
`"wrong state (unlocked)"` and returns `GST_FLOW_WRONG_STATE` instead of pulling from its internal
`GQueue`. This is the textbook `GstBaseSrc` pattern for interrupting a blocked streaming thread during
clean shutdown — `unlock()` exists specifically to wake up a `create()` call that's blocked waiting
for data, so the element's streaming task can notice the pending state change and exit instead of
hanging forever.

**Test:** extended `clonk_probe`'s player-active window from 25s to 90s (and the overall safety
timeout from 55s to 120s) to leave a much wider gap between the socket coming up and our own test's
intentional teardown, specifically to see whether "wrong state" still appeared *during* the active
window (real bug) or only right at teardown (timing artifact, as the flag semantics suggested).

**Result, from a fresh `--gst-debug=4` capture (`mediaserver_debug5.log`, 19150 lines):**
`gst_skype_rtp_src_create` logged `"wrong state (unlocked)"` exactly **once**, at `0:01:39.056` —
one line after `gst_skype_rtp_src_unlock:<rtp> unlock` at `0:01:39.056` and immediately following
`gst_skype_video_src_change_state:<clonkvhsrc> playing -> paused` at `0:01:38.975`. That's ~92 seconds
after the `rtp` element's `init` (`0:00:06.8`) — squarely at our own 90s wait-timer's teardown, not
during the active window. No other occurrence anywhere in the log. This confirms the hypothesis: the
message is benign, expected `GstBaseSrc` shutdown behavior triggered by our own test harness calling
`videoPlayerStop`, not a sequencing bug in the `RtpPacketReceived` call itself.

Also confirmed from the same log: `rtp:src` successfully linked to `depay:sink` and its streaming
task started (`gst_pad_start_task:<rtp:src>`) at `0:00:07.246`, well before any teardown — the pad
task lifecycle is healthy. (Actual per-buffer push/chain activity isn't visible at this log verbosity
— `gst_pad_push` traffic logs at `LOG`/`TRACE` level, above what `--gst-debug=4` captures — so this
doesn't yet prove a specific injected payload was pulled and forwarded downstream, only that the
pipeline's plumbing around `rtp` is correctly linked and running.)

**Conclusion:** part (a) of the "missing bits" is resolved — there is no remaining sequencing bug to
chase here. `RtpPacketReceived`, delivered via `skypekit_send_test`'s real-`.so`-linking technique,
reaches `VideoHost`'s `GstSkypeRtpSrc` element cleanly under normal (non-teardown) conditions.

**Device state, verified clean:** manually-started `mediaserver` (`--gst-debug=4` instance, PID 8899)
killed; normal upstart-managed instance restored via `start mediaserver` (new PID 20910); confirmed
healthy via `luna-send` afterward (same permission-denied-but-responsive pattern used throughout this
session as the health signal).

**Remaining work:** part (b) — the mirror-image outgoing path. `VideoHost::SendRTP` calls
`Sid::SkypeVideoRTPInterfaceCbClient::SendRTPPacket` (cmdId 4, confirmed in Part 10/13's disassembly)
over `/tmp/vidrtp_to_skypekit_key`, where **mediaserver is the client** (dialing out) — meaning a test
tool for this direction needs `vidrtp_sniffer`'s existing `server`-mode capability (already proven
working), not `skypekit_send_test`'s `client`-mode connect.

## Part 16 — found and fixed a real firmware caps-negotiation bug blocking capture entirely; the
outbound SkypeKit socket still never connects even with a genuinely working capture pipeline

Started part (b) by binding `vidrtp_sniffer` in `server` mode on `/tmp/vidrtp_to_skypekit_key` before
triggering `videoCaptureStart`, expecting to capture real `SendRTPPacket` bytes the way Part 12 did for
the incoming direction. No connection ever arrived, across several run shapes (capture alone, capture
held active while player also started, a stop/start retry pass). Rather than keep guessing at timing,
switched to a manual `--gst-debug=4` `mediaserver` instance to see what the capture pipeline itself was
actually doing.

**Found a real, blocking bug, not a timing issue.** `camsrc`'s `gst_base_src_start()` failed immediately
with `"Could not negotiate format"` on every run. The downstream `"Resolution Caps Filter"` capsfilter's
actual filter caps were `width=240, height=30, framerate=30/1` — not the `width=320, height=240` we
requested via `videoCaptureStart(320,240,30,400000)`. Those broken numbers are exactly our own `h=240`
and `fps=30` argument *values*, landed in the wrong caps fields — not defaults, not garbage. A stop/start
retry pass (mirroring the player-side workaround theory from Part 8/11) reproduced the identical broken
caps both times, ruling out a cache-timing bug and pointing at a genuine value/offset bug.

**Root-caused via disassembly of `ClonkPipeline::setCamCapsFilter()`** (`mediaserver` 0xb1fa0, found by
locating the `"Resolution Caps Filter"` element name at `.rodata` and cross-referencing
`gst_element_factory_make`). It calls `gst_caps_new_simple()` with:
- `framerate` = a literal `30/1` hardcoded directly in the instruction stream (never read from any
  settings object at all — explains why framerate was never the problem here, and also means our own
  `fps` argument no longer needs to literally be a valid framerate once repurposed, see below)
- `width` = `*(VideoSettings_object + 4)`
- `height` = `*(VideoSettings_object + 8)` (with a quirk: if that value is exactly `120`, it's remapped
  to `128` first — an unrelated special case that never triggered in our testing)

Cross-referencing against the empirically observed broken values: `+4` held our own `h` argument (240),
`+8` held our own `fps` argument (30). Since `ClonkSession::videoCaptureStart`'s `ClonkHostEvent` (the
object carrying our LS2 arguments into the pipeline, confirmed via disassembly of
`mediaserver` 0x6e9b0) stores them in plain order (`+12=w, +16=h, +20=fps, +24=bitrate`), and the
matching values line up field-for-field with no shift in the copy itself, the simplest and best-fitting
explanation is that `VideoSettings`'s own layout is likewise a plain, unshifted `(+0=w, +4=h, +8=fps,
+12=bitrate)` — and `setCamCapsFilter()` itself just reads one field too far for both properties: `+4`/
`+8` instead of the correct `+0`/`+4`. A real, shipped firmware bug in `mediaserver`, not something in
our probing.

**Fix (workaround, since we can only drive this through the LS2 API, not patch the binary): shift our
own argument values by one slot to compensate.** To land `width=320, height=240` in the actual applied
caps, call `videoCaptureStart` with `320` in the *height* argument slot and `240` in the *fps* argument
slot: `{"args":[320,320,240,400000]}`. Tested live and confirmed via a fresh `--gst-debug=4` capture
(`mediaserver_debug7.log`):
- `Resolution Caps Filter` intersects to exactly `width=320, height=240, framerate=30/1` — one of
  `camsrc`'s three valid discrete resolutions.
- `camsrc` transitions `READY → PAUSED → PLAYING` with **no** `"Could not negotiate format"` error —
  the first time this session capture ever got past that point.
- `getVideoCaptureActive` returns `true` (previously always `false` even when `videoCaptureStart`
  itself returned `{"returnValue":true}`) — independent confirmation the pipeline is genuinely running,
  not just nominally "started."
- The full downstream chain (`Camera Tee` → `Palm Video Encoder` → `Video Encoder Queue` →
  `clonkvhsink`/`skypevideosink`, plus a local `palmvideosink0` preview branch) constructs and later
  tears down with **zero** `busMsg_ERROR` or negotiation-failure messages anywhere in the log — the
  capture pipeline now runs cleanly end to end.

**However: even with a genuinely working capture pipeline, held active concurrently with an active
player for the full 90s window, `vidrtp_sniffer` in `server` mode on `/tmp/vidrtp_to_skypekit_key`
still never saw an incoming connection.** So there remains at least one further, distinct blocker
specific to the outbound SkypeKit socket setup — unlike the incoming direction (Part 12), which was
confirmed to start unconditionally given enough time once `videoPlayerStart` ran. Not yet identified;
candidates for a future session: `RunVideoHost()`/the AVTransport client-connect call may be gated
behind something neither `videoCaptureStart` nor `videoPlayerStart` alone trigger (e.g. an explicit
"begin streaming"/call-active signal a real `skypem` client would send that our raw LS2 probe never
does), or it may only fire once the encoder actually produces its first real encoded frame (worth
checking whether `Palm Video Encoder` ever emits a buffer, vs. just reaching `PLAYING` state with an
empty queue) — `--gst-debug=4` doesn't show per-buffer `gst_pad_push` traffic (that's `LOG`/`TRACE`
level), so this hasn't been directly confirmed either way yet.

**Device state, verified clean:** manually-started `mediaserver` (`--gst-debug=4` instance) killed;
normal upstart-managed instance restored via `start mediaserver`; confirmed healthy via `luna-send`
afterward (same pattern used throughout this session).

**Files changed:** `clonk_probe.c` — simplified back to a single `videoCaptureStart` call (removed the
now-disproven stop/start retry-pass workaround), applied the field-shift-compensated arguments, and
holds capture and player active concurrently for 90s (from Part 16's earlier "does the player path
trigger the outbound socket too" test, still a live open question above).

## Part 17 — resolved: the outbound connect is gated behind a client connecting to the *incoming*
socket first, confirmed by disassembly and reproduced live

Went looking for what actually triggers `mediaserver`'s outbound `AVTransportWrapper::Connect` on
`/tmp/vidrtp_to_skypekit_key`, since Part 16 left it unexplained. `RunVideoHost()` lives in
`libpalmgstskype.so`, not `mediaserver` itself — found via `GstSkypeInstance::RunVideoHost()`
(`libpalmgstskype.so` 0x29bc0).

**Disassembly of `RunVideoHost()` shows a strict, sequential two-phase structure:**
1. A loop repeatedly calling `Sid::AVServer::Connect(name="/tmp/vidrtp_from_skypekit_key", 10000)`
   until it returns success. `AVServer::Connect` (`libpalmgstskype.so` 0x3dd8c) is a thin wrapper —
   `return AVTransportWrapper::Connect(name, isServer=true, timeout=10000)` — and per Part 12's earlier
   `strace` finding, the server-role `Connect` does the *entire* bind+listen+`poll(timeout)`+**accept**
   cycle internally, retrying every ~10s if nothing connects. The loop only exits (falls through to
   phase 2) when this returns nonzero — i.e. **when something has actually connected** to the incoming
   socket. (There's a separate early-exit branch guarded by a shutdown flag at the `VideoHost` object's
   `+24` byte, unrelated to the success path.)
2. Only after that: `Sid::AVTransportWrapper::Connect(name=[the cached "/tmp/vidrtp_to_skypekit_key"
   transport], isServer=false, timeout=500)` at `libpalmgstskype.so` 0x29e90 — the outbound client
   connect we'd been waiting to see all of Part 16.

In other words: **`RunVideoHost()` will not even attempt to dial the outbound socket until a peer has
first connected to the inbound one.** Every Part 16 test had `vidrtp_sniffer` waiting in `server` mode
on the *outbound* socket in isolation, with nothing ever connecting to the *inbound* one during the
same run — so `RunVideoHost()` was permanently stuck in phase 1, never reaching phase 2. Not a
capture-pipeline bug, not an encoder-readiness gate — a strict ordering dependency between the two
sockets.

**Confirmed live, immediately.** Repeated the Part 16 setup (`vidrtp_sniffer server` on the outbound
socket, `clonk_probe` driving capture+player with the Part 16 caps fix), then — while both were
running — connected `skypekit_send_test` as a client to the *inbound* socket (the same proven
`RtpPacketReceived` call from Part 14). The moment it connected, `vidrtp_sniffer`'s log showed:
```
accepted connection, logging to /media/internal/vidrtp_to.log
logged 535 bytes
peer closed connection
```
535 real bytes from `mediaserver`, dialed out and sent within moments of our client connecting to the
other socket — the **first outbound SkypeKit traffic captured all session**, saved to
`vidrtp_to_captured_part17.log` in this directory. (First connect attempt failed with `AVTransportWrapper::Connect
failed (returned 0)` — a mundane timing artifact of landing between two of the ~10s bind/poll/accept
cycles on the inbound socket, not a repeat of this finding; a fast retry loop connected on the very
next attempt once timed tightly against the socket's appearance.)

The captured bytes start `5a 52 00 01 00 42 01 8d 04 80 ...` followed by ~500 bytes of high-entropy,
no-visible-structure data consistent with real encoded H.264 payload (the capture pipeline was healthy
and active per the Part 16 fix at the time of this run, so a real encoder frame being ready and sent
is plausible) — not yet decoded field-by-field. Given the proven, safe technique from Part 14
(link directly against the real `.so` rather than hand-reconstruct wire bytes), the natural next step
for actually consuming this direction is a `BinServer`/`rd_call`-based receive-side tool built the same
way, rather than reverse-engineering this capture by hand.

**Device state, verified clean:** manually-started `mediaserver` (`--gst-debug=4` instance) killed;
normal upstart-managed instance restored via `start mediaserver`; confirmed healthy via `luna-send`
afterward.

**Practical implication for the eventual bridge:** a real integration must keep a client connected to
`/tmp/vidrtp_from_skypekit_key` (or otherwise satisfy `RunVideoHost()`'s first-phase accept) *before*
or *concurrently with* relying on the outbound socket ever being dialed — the two directions are not
independent from `mediaserver`'s point of view, even though they're logically separate sockets.

## Part 18 — decoded the 535-byte capture: it's a real, standard RTP/H.264 packet, extracted using
the real `Sid::Protocol::BinServer` decoder rather than hand-parsing

Rather than reverse-engineer Part 17's captured bytes by hand (risky, per Part 13's lesson), built
`skypekit_decode_test`, which reuses the exact same safe technique as `skypekit_send_test` (Part 14) —
link directly against the real, extracted `libpalmgstskype.so` and call its actual compiled decoder —
but for reading instead of writing. Two local processes talk over a throwaway abstract socket (no
dependency on `mediaserver` at all): a `client` mode that connects and calls
`Sid::AVTransportWrapper::bl_write_bytes()` — a **raw** byte writer, bypassing `BinClient`'s own
message encoding entirely — to replay Part 17's exact captured bytes verbatim onto the wire; and a
`server` mode that constructs a real `Sid::Protocol::BinServer` around the accepted connection and
calls its actual `rd_call`/`rd_parms` to decode whatever arrives.

**First attempt skipped a required framing step and produced garbage** (`rd_call` returned
`cmdId=0, arg2=90, arg3=82` — suspiciously close to the ASCII values of the capture's own first two
bytes). Root cause, found via disassembling `BinCommon::rd_command` (`libpalmgstskype.so` 0x41824):
every message on the wire starts with **exactly 2 raw bytes** — byte0 must equal the fixed sync byte
`0x5a` (`'Z'`, checked internally, mismatch is an error) and byte1 is stored as the message's "type"
(compared against `0x52`='R' by `ProcessCommands`, meaning "this is a call"). `ProcessCommands` always
calls `rd_command` before `rd_call`; skipping it left the real decoder's read position off by 2 bytes,
desyncing everything downstream. This also resolved Part 17's open question about what the leading
`5a 52` bytes were — not a "cmdName" string, but this 2-byte sync+type header. (The matching 4-byte
`5a 52 00 01 00 00 00 00`-style entries found in `.rodata` alongside the actual field table pointers
appear to be a *different*, per-interface class-identifier tag — not directly written to the wire in
this form — a detail that no longer matters now that the real bytes decode cleanly regardless.)

**Fixed by calling `rd_command` first, then `rd_call`, then `rd_parms`** with
`Sid::Field::M_SkypeVideoRTPInterfaceCb_fields` at index 0 (the same field table confirmed via
disassembly of `SendRTPPacket`'s own encode call in Part 17) — and it worked cleanly:
```
rd_command returned 0, type=0x52 ('R')
rd_call returned 0, cmdId=0 arg2=0 arg3=1
rd_parms returned 0
decoded SEBinary: data=0x23d18 len=525
```
(`cmdId=0` here doesn't mean much on its own — this precompiled/"preencoded" call path apparently
doesn't round-trip a meaningful numeric cmdId through `rd_call` the same way a plain `wr_call_lst`
string-named call would; not worth chasing further now that the payload itself decoded correctly.)

**The decoded 525-byte payload is a real, standards-compliant RTP packet carrying genuine H.264 video
data** — not a SkypeKit-proprietary wrapper:
- Byte 0 = `0x80` → RTP version 2, no padding, no extension, no CSRC — a completely ordinary RTP
  header first byte.
- Byte 1 = `0xe0` → marker bit set (`1`), payload type `96` — exactly the dynamic payload type seen
  in the pipeline's own negotiated caps (`application/x-rtp, payload=(int)[96, 127], ...,
  encoding-name=(string)H264`, Part 15).
- Bytes 2–3 = sequence number `0xf83c`; bytes 4–7 = timestamp `0x89e6687f`; bytes 8–11 = SSRC
  `0x7bb6139b` — all present and well-formed.
- Byte 12 (first payload byte) = `0x41` → a valid H.264 NAL unit header (`nal_ref_idc=2,
  nal_unit_type=1`, "coded slice of a non-IDR picture") — exactly what real inter-frame H.264 video
  data looks like.

This is strong, direct confirmation that: (1) the Part 16 caps fix produced a genuinely working
capture pipeline that really did encode a real video frame, (2) `SendRTPPacket` carries standard RTP
with standard H.264 payloads — no SkypeKit-specific frame wrapping to reverse-engineer beyond the
2-byte sync/type header and the generic `Field`-table SEBinary framing already decoded — which is very
good news for the eventual bridge: the payload itself can be handled with completely ordinary RTP/H.264
tooling, matching what `meowcaller`/`whatsmeow`'s `Call.SendVideo` already expects.

**Saved locally for reference:** `vidrtp_to_captured_part17.bin` (the raw 535-byte capture),
`decoded_rtp_packet_part18.bin` (the extracted 525-byte RTP packet), both in this directory.

**Device state:** this test never touched `mediaserver` at all (two local processes talking to each
other over a throwaway abstract socket) — confirmed still healthy via `luna-send` afterward regardless.

**Files added:** `skypekit_decode_test.cpp`, `build-skypekit-decode-test.sh`.

## Part 19 — hooked it up: a real native SkypeKit<->meowcaller video bridge, built and linked
into the actual WhatsApp calling plugin

Built the real integration described in this session's "hook it up properly" plan (full plan
text in the session transcript; summary here). New files, all in
`messaging/facebook-e2ee/plugin/purple-combined/`:

- **`glue/h264_rtp.h`/`.c`** — a pure-C, socket-free RFC 6184 depacketizer (RTP payload + marker
  bit -> Annex-B access units, handling single-NAL, STAP-A, and FU-A) and packetizer (access
  unit -> RTP payloads, FU-A-fragmenting anything over an MTU). Round-trip tested standalone
  (7 cases: single/multi-NAL, FU-A at two MTUs, a mixed access unit, and the start-code-adjacent
  trailing-zero edge case) — all pass.
- **`glue/skypekit.h`/`.cpp`** — the actual SkypeKit socket bridge, linking directly against the
  real `libpalmgstskype.so` via the same asm-mangled-symbol trick as `skypekit_send_test.cpp`/
  `skypekit_decode_test.cpp`. Two threads: Thread A binds+listens `/tmp/vidrtp_to_skypekit_key`
  and decodes each `SendRTPPacket` call with the real `BinServer` (Part 18's technique), handing
  completed access units to Go; Thread B connects as a client to
  `/tmp/vidrtp_from_skypekit_key` and, on each access unit Go hands it, RTP-packetizes and sends
  it as one or more real `RtpPacketReceived` calls (Part 14's technique), maintaining real
  sequence/timestamp/SSRC state across the call.
- **`glue/call.c`** — `clonk_open`/`clonk_close` deepened from bare session tracking into the
  real sequence: session create -> `videoCaptureStart` (Part 16's field-shift-compensated args)
  -> `skypekit_video_start()` (binds Thread A) -> `videoPlayerStart` (triggers `RunVideoHost()`) ->
  Thread B's connect loop. Teardown mirrors it in reverse.
- **`call.go`** (plugin-level) — `attachMedia` now also wires `Call.ReceiveVideo` to
  `skypekit_video_receive_frame` (peer video -> native display), and a new exported
  `gowhatsapp_call_video_frame_out` (native capture -> `Call.SendVideoWithDuration`) routes to
  whichever call is currently live, matching this file's existing single-live-call convention.
- **`build-combined.sh`** — compiles `skypekit.cpp` with g++ (`-fno-rtti`) and `h264_rtp.c`
  alongside the existing glue objects, links `-lpalmgstskype`, and — unlike every standalone test
  tool this session, which needed `LD_LIBRARY_PATH` set manually — bakes
  `-Wl,-rpath,/usr/lib/gstreamer-0.10` into the built plugin so it finds the real `.so` at
  runtime unconditionally.

**A real pthread deadlock, found and fixed via live testing before it ever reached the full
plugin.** First version cancelled both bridge threads on stop via `pthread_cancel`. Thread B
(the peer->display queue-wait) hung on shutdown, confirmed live: `/proc/<pid>/task` showed the
process down to one thread blocked in `futex_wait_queue_me` — cancelling a thread blocked in
`pthread_cond_wait`/`cond_timedwait` re-locks the mutex as part of POSIX's cancellation cleanup,
and without a `pthread_cleanup_push` to release it, that mutex stays locked forever once the
thread exits, deadlocking `skypekit_video_stop()`'s own later lock of it. Fixed by making Thread
B fully cooperative instead: every blocking call it makes is naturally bounded (`avtw_connect`'s
own timeout, or `pthread_cond_timedwait` with an explicit `g_running` check), so it always exits
on its own and is never cancelled. Thread A still uses `pthread_cancel` (safe — it never touches
that mutex).

**Confirmed live, end to end, before wiring the rest.** Built a standalone smoke-test harness
(`skypekit_bridge_selftest.c` — stands in for meowcaller, logging frames from Thread A and
pushing a synthetic access unit into Thread B) and ran it alongside `clonk_probe` (already
carrying the Part 16 fix) against a `--gst-debug=4` `mediaserver`:
```
wa-call: skypekit thread B connected to mediaserver
wa-call: skypekit thread A accepted a connection
[selftest] frame_out: 1504 bytes, first 16: 00 00 00 01 67 42 c0 0c e9 02 83 f2 00 00 00 01
```
Thread B's connection is what unlocked Thread A's accept, exactly as Part 17 predicted — in
production code this time, not a hand-built test tool. And the decoded access unit is a real,
multi-NAL H.264 stream starting with a genuine SPS (`0x67`, profile `0x42` = Baseline) followed
immediately by another NAL — i.e. mediaserver's own encoder emits a proper SPS+PPS+IDR opening
sequence, which is exactly what meowcaller's `videoSender` needs (it silently drops every access
unit until one contains a real IDR). The `--gst-debug=4` log showed zero pipeline errors
throughout.

**Open question, not yet resolved: the connection closed after that one access unit and never
reopened for the rest of the 90s test window**, with no GStreamer errors visible anywhere in the
log. This matches a real, already-flagged risk from the `RunVideoHost()` disassembly (Part 17):
its phase-2 outbound dial is a *single* 500ms-timeout attempt, not wrapped in a retry loop the
way phase-1 is — so if that one connection ever drops, nothing in the native firmware appears to
re-establish it within the same `RunVideoHost()` invocation. Whether this actually blocks a real,
sustained WhatsApp video call (as opposed to this synthetic, short-lived `clonk_probe`-driven
test) is unconfirmed — a real call may keep the session alive differently. **This is the most
important thing to check first during real end-to-end call testing.**

**Verified:** the full `build-combined.sh` build succeeds — `skypekit.cpp`/`h264_rtp.c` compile
cleanly, the final `libwhatsmeow.so` link succeeds, `NEEDED` correctly lists
`libpalmgstskype.so`, `RPATH` is `/usr/lib/gstreamer-0.10` as intended, and both the Go export
(`gowhatsapp_call_video_frame_out`) and the new C entry points
(`skypekit_video_start`/`_stop`/`_receive_frame`) are present and correctly typed in the final
binary, with every SkypeKit symbol showing as an unresolved `U` deferred to the real `.so` at
runtime — the plugin itself has not yet been deployed and exercised through a real WhatsApp video
call.

**Device state:** all test processes (`skypekit_bridge_selftest`, `clonk_probe`) killed; manually
started `--gst-debug=4` `mediaserver` killed; normal upstart-managed instance restored via
`start mediaserver`; confirmed healthy via `luna-send` afterward.

**Files added:** `messaging/facebook-e2ee/plugin/purple-combined/glue/{h264_rtp.h,h264_rtp.c,
skypekit.h,skypekit.cpp}`, `messaging/whatsapp/calling/{skypekit_bridge_selftest.c,
build-skypekit-bridge-selftest.sh}`. **Files changed:** `glue/call.c`, `call.go`,
`build-combined.sh`.

**Next steps:** deploy the built plugin and place a real, sustained WhatsApp video call between
two accounts, one being the TouchPad. Confirm outgoing video reaches the peer and incoming peer
video renders natively — and specifically watch whether the outbound connection survives for the
call's duration or exhibits the same single-frame-then-drop behavior seen in this synthetic test.

## Part 20 — deployed to the live device and placed a real WhatsApp video call: the native
bridge activated successfully in production

Deployed `build-arm/libwhatsmeow.stripped.so` (the plugin built in Part 19) onto the TouchPad,
replacing the live `com.palm.app.teams/backend/lib/purple-2/libwhatsmeow.so` (backed up first to
`libwhatsmeow.so.b4vidbridge`, matching this codebase's existing `.b4*` backup convention). First
`novacom put` attempt silently truncated the file to 0 bytes mid-transfer (a known failure mode
`deploy-whatsapp.sh` already documents) — as a side effect, the already-running old
`imlibpurpletransport` process SIGBUS'd (its mmap'd `.so` shrank out from under it). Retried with
byte-count verification (matching `deploy-whatsapp.sh`'s `put_verify` pattern) and it landed
intact; restarted the transport (SIGTERM + clear the PmLog semaphore, matching
`deploy-whatsapp.sh` step 4d) and it came back up clean via upstart respawn.

**Confirmed the new plugin loads correctly**: `callStateQuery` responded immediately after
restart, meaning `whatsapp_call_luna_init()` — and therefore the whole plugin, including the new
`skypekit.cpp`/`h264_rtp.c` code linked into it — initialized without crashing. The
`-Wl,-rpath,/usr/lib/gstreamer-0.10` link flag (Part 19) worked exactly as intended: no
`LD_LIBRARY_PATH` was set for this launch (confirmed by reading the actual launch chain,
`/etc/event.d/imtransport` -> `/var/imdaemon.sh` -> `/var/imwrap.sh`, none of which reference
`gstreamer-0.10`), yet `libpalmgstskype.so` still resolved.

**Placed a real call** via `luna-send` (`dial {"address":"+31...","video":true}`) — connected
successfully (real call id, audio confirmed working both directions per the log). Dialing with
`video:true` only sends the WhatsApp-protocol video-upgrade signal, though; the *native* clonk
session only opens on an explicit `changeMedia {"outgoingVideo":true}` (normally sent by the Phone
app's video-call UI, not bundled into dial itself) — sent that manually next, and the native
video bridge came up, logged live from `/media/cryptofs/imstdout.log` (the real destination of
this plugin's stderr, traced through `/etc/event.d/imtransport`'s upstart job — `console none` ->
`imdaemon.sh` -> `imwrap.sh`'s final `>> /media/cryptofs/imstdout.log 2>&1`, not
`/var/log/messages`):
```
wa-call: clonk session open: palm://com.palm.mediad.Clonk_23452/
wa-call: clonk videoCaptureStart: {"returnValue":true}
wa-call: skypekit thread A accepted a connection
wa-call: skypekit thread B connected to mediaserver
wa-call: clonk videoPlayerStart: {"returnValue":true}
```
Both SkypeKit socket threads connected in a real call, for the first time — not a synthetic test
harness. The call ended a short time later (cause not directly observed — could be either party
hanging up, or a timeout); teardown was clean (`videoPlayerStop`/`videoCaptureStop` both
succeeded, no crash, no error), and `imlibpurpletransport` remained the same stable process
throughout (no restart needed) with `callStateQuery` still responsive afterward.

**Not yet directly confirmed:** whether real camera video actually reached the peer's screen, or
whether the peer's video rendered on the TouchPad's own display — this requires the human on the
other end of the call to report what they actually saw, which wasn't available from the device
logs alone in this pass. The architecture-level milestone (both native SkypeKit sockets
connecting successfully inside a real, unmodified WhatsApp call flow) is confirmed; visual/quality
confirmation is the next thing to check.

**Device state:** `imlibpurpletransport` (PID 7619) and `mediaserver` both left running normally,
undisturbed since this deploy — no manual debug instance was used for this test (unlike every
earlier synthetic test this session) since this was a real, production call, not a lab test.

**Confirmed by the human on the other end: real video, correctly decoded.** The peer's phone
showed the TouchPad's own living room — genuine, visually-correct camera output, not just "bytes
arrived." This closes out the outgoing (capture -> peer) direction end to end: native `camsrc` ->
`Palm Video Encoder` -> `SendRTPPacket` -> Thread A's decode/depacketize -> `Call.SendVideo` ->
the real WhatsApp relay -> the peer's phone, all through the code written in Part 19, working the
very first time it ran in a real call. The incoming (peer -> TouchPad display) direction's visual
confirmation is still open — Thread B connected, but whether real peer frames actually rendered on
the TouchPad's own screen during this same call hasn't been confirmed yet.

## Part 21 — a second, longer real call: reconnect resilience confirmed live, real incoming
video frames flowed, and a keyframe-request workaround added

Placed a second real call (same live device, `--gst-debug=4` `mediaserver` this time for
visibility). Two things this run confirmed that the "hook it up properly" plan had left as open
risks:

- **Reconnect resilience already worked, without any new code.** `skypekit.cpp`'s Thread A and
  Thread B both retry in their own outer loops after any disconnect (Thread A re-binds/listens,
  Thread B re-connects) — this was already in the Part 19 code, just not yet exercised by a real
  disconnect. This call logged `thread B connected` -> `disconnected, retrying` -> `connected`
  again, entirely on its own, with real video flowing after the second connect. The
  single-shot-outbound-dial risk flagged in Part 19 (from the `RunVideoHost()` disassembly) turned
  out not to matter in practice: a real, sustained call behaves differently from the short
  synthetic `clonk_probe` test that risk was originally observed in.
- **Real incoming video frames were decoded and forwarded, not just a connection.** Once the
  peer's phone started actually transmitting (partway into the call), `imstdout.log` showed
  repeated `skypekit thread B sending access unit` lines (peer -> TouchPad direction is actually
  named misleadingly in that log string — this is Thread B decoding real inbound frames and
  handing them to the native player), and `mediaserver`'s own `clonk_vplay_h264dec`
  (`palm_videodecoder`, the real hardware decoder) reached `PLAYING` with zero errors. Direct
  on-screen visual confirmation of this direction is still outstanding — the call ended
  (or went quiet, cause unconfirmed) before that could be checked.

**Added a keyframe-request workaround.** `Call.OnVideoKeyframeRequest` (fired on the peer's
authenticated PLI/FIR feedback) is now wired to a new `gowhatsapp_call_request_keyframe()`
(`glue/call.c`), which stops and restarts capture (`videoCaptureStop` then `videoCaptureStart`
with the Part 16 compensated args) — no separate keyframe request exists on the native LS2
surface, but every capture start emits a real SPS/PPS/IDR opening sequence (confirmed in every
real call so far), so forcing a restart is a working, if heavier-handed, substitute. `call.go`'s
`wireCall` now registers this alongside the other `mcCall.On...` callbacks. Full `build-combined.sh`
build verified clean; `gowhatsapp_call_request_keyframe` confirmed present and correctly typed in
the linked `.so`. Not yet exercised against a real PLI/FIR from the peer (only compile/link
verified) — the packet-loss conditions that trigger it didn't occur during this session's calls.
