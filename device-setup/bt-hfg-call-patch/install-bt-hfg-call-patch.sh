#!/bin/bash
# bt-hfg-call-patch: 1-byte patch of the stock PmBtEngine so its HFG (Bluetooth hands-free GATEWAY) call
# path accepts VoIP calls from ANY transport, not only "com.palm.skype".
#
# Background (see memory note bluetooth-call-audio-sco): the TouchPad's Bluetooth call audio (tablet as
# Audio Gateway -> BT headset over HFP/SCO) is wired for Skype only. PmBtEngine's CurrentCallsCallback ->
# PmBtCreateCallStatusMessage reads each call's "transport" and, unless it == "com.palm.skype", logs
# "Transport is not skype, so not handling it" and drops the call. So WhatsApp/Telegram/Signal calls never
# reach the HFG gateway.
#
# The gate is a single branch (ARMv7):
#   0x253e8  bl  PmBtOsStrNCmp(transport, "com.palm.skype", 14)
#   0x253ec  cmp r0, #0
#   0x253f0  0a000031  beq 0x254bc   (accept ONLY if == com.palm.skype)   <-- PATCH
# Flipping the condition EQ->AL makes it accept ANY transport (future-proof - Teams/Discord/... too):
#   0x253f0  ea000031  b   0x254bc
# = one byte at file offset 0x1d3f3: 0x0a -> 0xea.
#
# Reversible: /usr/bin/PmBtEngine.orig backup is kept; restore it + restart bluetooth to undo.
# Verified against topaz PmBtEngine md5 9e0a25919fcb48fd1e636d90b6ef1b4d.
set -e
DEV="${DEV:-topaz-linux}"

printf '%s\n' '
BIN=/usr/bin/PmBtEngine
printf "\061\000\000\012" > /tmp/ref_before   # 31 00 00 0a  (beq)
printf "\061\000\000\352" > /tmp/ref_after    # 31 00 00 ea  (b)
dd if=$BIN bs=1 skip=119792 count=4 2>/dev/null > /tmp/got
if cmp -s /tmp/got /tmp/ref_after; then echo "ALREADY PATCHED - nothing to do"; exit 0; fi
if ! cmp -s /tmp/got /tmp/ref_before; then echo "ABORT: bytes @0x1d3f0 are not 31 00 00 0a (unexpected build) - no changes"; exit 1; fi
echo "stopping bluetooth..."; stop bluetooth 2>/dev/null; sleep 2
kill $(pidof PmBtEngine PmBtStack BluetoothMonitor) 2>/dev/null; sleep 2
mount -o remount,rw / 2>/dev/null
[ -f $BIN.orig ] || cp $BIN $BIN.orig
printf "\352" | dd of=$BIN bs=1 seek=119795 count=1 conv=notrunc 2>/dev/null
dd if=$BIN bs=1 skip=119792 count=4 2>/dev/null > /tmp/got2
if cmp -s /tmp/got2 /tmp/ref_after; then echo "PATCHED OK (31 00 00 ea)"; else echo "PATCH FAILED - restoring"; cp $BIN.orig $BIN; fi
rm -f /tmp/ref_before /tmp/ref_after /tmp/got /tmp/got2
echo "starting bluetooth..."; start bluetooth 2>/dev/null; sleep 3
ps -ef | grep -v grep | grep -E "BluetoothMonitor|PmBtStack" | head
' | novacom -d "$DEV" run file://bin/sh
echo "=== done. To undo: cp /usr/bin/PmBtEngine.orig /usr/bin/PmBtEngine ; stop bluetooth ; start bluetooth ==="
