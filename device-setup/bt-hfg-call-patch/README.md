# bt-hfg-call-patch — let Bluetooth call audio work for non-Skype VoIP

## What
A 1-byte patch of the stock `/usr/bin/PmBtEngine` so its HFG (Bluetooth hands-free **gateway**) call path
accepts VoIP calls from **any** transport, not only `com.palm.skype`.

## Why
The TouchPad's Bluetooth *call* audio (tablet acts as the Audio Gateway pushing call audio to a BT headset
over HFP/SCO) was wired for **Skype only** (webOS shipped Skype as the built-in VoIP caller). PmBtEngine's
`CurrentCallsCallback` → `PmBtCreateCallStatusMessage` reads each call's `transport` field and, unless it
equals `com.palm.skype`, logs *"Transport is not skype, so not handling it"* and drops the call. So
WhatsApp / Telegram / Signal calls never reach the HFG gateway → no Bluetooth call audio.

## The patch
ARMv7 gate in `PmBtEngine`:
```
0x253e8  bl  PmBtOsStrNCmp(transport, "com.palm.skype", 14)
0x253ec  cmp r0, #0
0x253f0  0a000031  beq 0x254bc      accept ONLY if == com.palm.skype   <-- patched
0x253f0  ea000031  b   0x254bc      accept ANY transport (EQ -> AL)
```
= one byte at file offset **0x1d3f3: `0x0a` → `0xea`**. Future-proof (any new service works, no list).

## Install / uninstall
```
bash install-bt-hfg-call-patch.sh          # DEV=topaz-linux
# undo:
#   cp /usr/bin/PmBtEngine.orig /usr/bin/PmBtEngine ; stop bluetooth ; start bluetooth
```
Verified against topaz `PmBtEngine` md5 `9e0a25919fcb48fd1e636d90b6ef1b4d`; aborts safely if the bytes
don't match. Backup kept at `/usr/bin/PmBtEngine.orig`.

## Not sufficient alone (status 2026-07-28)
This clears the transport gate, but two more things are needed for audio to actually reach the headset,
and are NOT yet solved (see memory `bluetooth-call-audio-sco`):
1. Each IM call plugin must send `CallStatusUpdate` with **`"id"` as a STRING** (PmBtEngine reads it as a
   string; an int → "Failed to find call ID"). Fixed in WhatsApp (`glue/call.c`) + Telegram
   (`call-luna.cpp`); Signal doesn't send `CallStatusUpdate` yet (TODO).
2. audiod must **enable + select `phone_bluetooth_sco`** and the **SCO voice channel must open** — the deep
   `audiod ↔ PmBtEngine ↔ SCO` handshake, still under investigation.
