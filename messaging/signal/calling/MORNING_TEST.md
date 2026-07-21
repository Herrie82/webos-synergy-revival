# Signal calling — media wire-up: how to test

Overnight 2026-07-21 the Signal call **media engine** was proven on-device and **wired into
presage**. This is the deploy + test recipe. The whole stack compiles; the signaling round-trip and
ICE are ready to exercise. Two-way audio has one remaining unverified input (the SRTP KDF ids, see
bottom) so treat the first call as a signaling/ICE test that may or may not yield audio.

## What's proven vs unproven
- ✅ `signal_media --loopback` round-trips 25 Opus frames through AEAD_AES_256_GCM SRTP **on device**.
- ✅ `signal_media --answer` IPC: parses START, gathers ICE, emits PUB + bare `candidate:` lines.
- ✅ presage `call_bridge.rs` compiles into `libpresage.so`, relays offer→Answer + ICE both ways.
- ❓ Real ICE connectivity to a live Signal peer (LAN host candidates should connect).
- ❓ Two-way audio — depends on the SRTP KDF ids (see "Remaining unknown").
- ❓ ALSA `voip`/`voipsource` routing under a live call (same recipe as Telegram; may need the
     system libasound + audiod scenario that call.c drives).

## Deploy (host → device)

1. **GCM libsrtp2** (once): the stock wpe-252 libsrtp2 has no AES-GCM.
   ```
   novacom put file:///media/internal/sslfix/libsrtp2.so.1 \
     < messaging/signal/calling/media/prebuilt/libsrtp2.so.1
   ```
   (Rebuild with `messaging/signal/calling/media/build-libsrtp2-gcm.sh` if needed.)

2. **Media engine** (patchelf'd to the wpe-glibc loader, host has patchelf):
   ```
   WPE=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
   cd messaging/signal/calling/media && ./build-signal-media.sh
   patchelf --set-interpreter /media/internal/wpe-glibc/lib/ld-linux.so.3 \
     --set-rpath "/media/internal/sslfix:/media/internal/wpe-glibc/lib:$WPE/lib:/usr/lib:/lib" signal_media
   novacom put file:///media/internal/signal_media_p < signal_media
   # (chmod +x /media/internal/signal_media_p on device)
   ```

3. **presage plugin** (rebuilt libpresage.so with the bridge):
   ```
   messaging/signal/build-presage.sh   # then deploy plugin/purple-presage/build-arm/libpresage.so
   ```
   (Deploy libpresage.so where imlibpurpletransport loads it, per the existing Signal deploy.)

4. **Sanity-check the engine alone** on device (should print PASS):
   ```
   env LD_LIBRARY_PATH=/media/internal/sslfix:/media/internal/wpe-glibc/lib:$WPE/lib:/usr/lib:/lib \
       GST_PLUGIN_PATH=$WPE/lib/gstreamer-1.0 GST_REGISTRY=/media/internal/gstreg-sig.bin \
       /media/internal/signal_media_p --loopback
   ```

## Arm + run the test
- **Enable media auto-answer** (the gate; without it, calls just ring like v1):
  ```
  touch /media/internal/signal_call_media
  ```
- Restart the Signal transport (or the messaging service) so the new libpresage.so loads.
- From another phone, **place a Signal voice call TO the device**. Expect:
  - Phone app rings (existing v1 behaviour), AND
  - presage spawns `signal_media --answer`, sends an Answer, trickles our ICE candidates,
    feeds the caller's candidates to the engine.
- **Disable auto-answer** afterwards: `rm /media/internal/signal_call_media`.

## Where to look
- presage debug log: `call bridge: sent Answer to <uuid>` / `sent IceUpdate` lines confirm the
  outgoing signaling fired.
- `/media/internal/sigoffer.log` still dumps raw offer/answer/ICE opaques (DIAG in receive.rs).
- The engine's own stderr is dropped (Stdio::null) when spawned by presage; to see engine logs run
  the standalone `--answer` harness (see RUNTIME_STATUS.md) or temporarily point stderr to a file.

## Remaining unknown (blocks two-way audio, not signaling)
The SRTP master keys come from `signal_negotiate_srtp_keys(our_priv, peer_pub, caller_id, callee_id)`
with HKDF info = `"Signal_Calling_20200807_SignallingDH_SRTPKey_KDF" + caller_id + callee_id`. The
exact `caller_id`/`callee_id` bytes (RingRTC identity material) are **unverified** — `call_bridge.rs`
passes them EMPTY. If ICE connects but audio is silent/garbled, this is the cause. To resolve: get
RingRTC's exact V4 SRTP-key derivation (what it concatenates as caller/callee id) and fill those in
`call_bridge::start_incoming` (they must match what the peer uses, or the keys won't agree).
