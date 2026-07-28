# bt-a2dp-fix — Bluetooth A2DP media auto-stream fix (webOS 3.0.5 TouchPad)

## Problem
When a Bluetooth headset connects, music/media is **mute** (system sounds still play on the speaker,
and AVRCP track controls work). audiod *does* route media to the pulse `a2dp` sink, but the BT stack's
A2DP stream never actually streams to the headset.

## Root cause (traced on device)
The A2DP AVDTP stream only reaches **`Connected Open`** (then **`Connected Streaming`**) on a
**device-initiated** connect (which a fresh BT stack performs). **Headset-initiated** reconnects (turn
the headset off/on, auto-reconnect) stall at **`Connected`** — the stream endpoint never opens — so audio
written to the `a2dp` FIFO goes nowhere. Even at `Connected Open`, nothing issues the `a2dp/play` that
advances to `Connected Streaming`.

Confirmed working recipe (sound verified through a Logitech H800):
1. a fresh/device-initiated connect reaches `Connected Open`
2. `luna-send palm://com.palm.bluetooth/a2dp/play {"address":...}` → `Connected Streaming` → audio
   (`a2dp/audioActivity {"active":true}` alone does **not** start it.)

## What the daemon does
`bt-a2dp-fix.sh` polls the A2DP state (from `/var/log/bt.log`, the only place the fine AVDTP sub-states
appear) and:
- **`Connected` stall** (no open within ~6s) → restarts the BT stack (`kill $(pidof PmBtEngine PmBtStack
  BluetoothMonitor)` — an upstart `respawn` job, so it comes back fresh and device-initiates the connect →
  `Connected Open`). Rate-limited by a 45s guard so it can never storm.
- **`Connected Open`** → issues `a2dp/play` (once) → `Connected Streaming` → audio flows.

Note: the stack restart briefly drops **all** Bluetooth (incl. HID). It only fires on a genuine A2DP
stall (right after you turn a headset on), never on a healthy connect, and is guarded.

## Install
```
bash install-bt-a2dp-fix.sh          # DEV=topaz-linux by default
```
Installs `/usr/sbin/bt-a2dp-fix.sh` + the upstart job `/etc/event.d/bt-a2dp-fix` (respawn, starts on boot)
and starts it. Log: `/var/log/bt-a2dp-fix.log`.

## Not covered / TODO
- **Call audio over Bluetooth** is a *separate* profile (HFP/SCO + the `phone_bluetooth_sco` audiod
  scenario), not A2DP — this daemon does not address it.
- Optimization: whether a lighter device-initiated `a2dp/connect` can replace the full BT-stack restart
  (untested — the connect LS method wasn't confirmed).
