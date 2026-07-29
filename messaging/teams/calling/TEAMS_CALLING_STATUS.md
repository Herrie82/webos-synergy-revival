# Teams NGC voice calling — status & morning runway

Overnight build of native Microsoft Teams 1:1 voice calling for the webOS Teams connector
(`purple-teams`). This is the "Option A" full-native path. Everything that does **not** need a
live-call capture is built, compiling for ARM, and ready to deploy. The remaining work is the
media engine, which is a **bounded diff** once we have one real call captured.

---

## TL;DR

- **Protocol (settled by research):** Teams calls use **NGC** (NextGenCalling / legacy Skype
  media), NOT WebRTC. SDES-SRTP (`AES_CM_128_HMAC_SHA1_80`), master key delivered out-of-band in
  `udpKey.sessionKey`; **no DTLS**. Media via a single **MS-TURN** relay (`:3478`) authed by
  `udpKey.ticket` (MRAS). Codecs SILK / Satin / G.722 (**not** Opus). No open-source engine exists
  to lift wholesale, but every piece is documented/standard except MS-TURN's ticket auth.
- **Built tonight (all compile for ARM):** capture harness, full NGC signaling module, the webOS
  LS2 Phone-app bridge (`com.palm.teams.call`), the account PHONE capability + LS2 role/service
  grants, and the media-engine base + adaptation spec.
- **Blocking unknowns (need ONE captured call):** exact SDP dialect + codec list, whether the SRTP
  key is in the SDP `a=crypto` or only `udpKey.sessionKey`, and the MS-TURN allocate/auth shape.
- **Morning step 1:** deploy, place/receive a real Teams call, read
  `/media/internal/teams-call-capture.log`.

---

## Architecture (two layers)

**Layer 1 — webOS bridge (DONE, reused pattern).** Stock Phone app ⇄ `com.palm.teams.call`
(LS2: `dial/answer/disconnect/callStateQuery`) ⇄ `teams_calling.c`. Copied from the working
Telegram/WhatsApp mediators.

**Layer 2 — network media (signaling DONE, media = the remaining work).** `teams_calling.c` parses
the NGC offer and drives the control plane; `teams_media` (a fork of Signal's on-device-proven
gst-1.20 nice+srtp+alsa engine) will move the audio.

```
Stock Phone app (CallSynergizer)
        │  LS2 com.palm.teams.call  (dial/answer/disconnect/callStateQuery)
        ▼
teams_call_luna.c ──registers state cb──► teams_calling.c
        ▲                                        │ parses NGC offer (sdp/udpKey/links)
        │ push state (incoming/active/…)         │ reject/answer/hangup over the control links
        │                                        ▼
   audiod (phone scenario)              teams_media  (RX/TX SRTP+codec via MS-TURN relay)  ← TODO
                                          alsasink=voip / alsasrc=voipsource
```

## What's built (files)

| File | What | Status |
|---|---|---|
| `plugin/purple-teams/teams_calling.{c,h}` | Capture + NGC parse + state machine + reject/answer/hangup/dial | **compiles** |
| `plugin/purple-teams/teams_call_luna.{c,h}` | LS2 `com.palm.teams.call` bridge (dial/answer/disconnect/callStateQuery + audiod) | **compiles + links LS2** |
| `plugin/purple-teams/teams_trouter.c` | NGC handler now hands off to `teams_calling_handle_trouter()` (was: printed "Incoming call") | **compiles** |
| `plugin/purple-teams/libteams.{c,h}` | `active_call` field; `teams_call_luna_init()` on login (guarded `TEAMS_WEBOS_CALL`) | **compiles** |
| `account/com.palm.teams/com.palm.teams.json` | + PHONE capabilityProvider → `palm://com.palm.teams.call/` | done |
| `imlibpurpleservice/.../ls2/roles/{pub,prv}/com.palm.imlibpurple.json` | grant `com.palm.teams.call` bus name | done |
| `teams/calling/ls2/roles/pub/com.palm.teams.call.json`, `teams/calling/dbus-1/.../com.palm.teams.call.service` | call-service role + registration | done |
| `build-teams.sh` | builds the calling files + links luna-service2 + `-DTEAMS_WEBOS_CALL` | **builds `libteams-personal.stripped.so`** |
| `teams/calling/media/` | Signal engine seeded as reference + `TEAMS_MEDIA_ADAPTATION.md` (Δ1-4) + `build-teams-media.sh` | spec ready |

Build: `cd messaging/teams && bash build-teams.sh` → `libteams-personal.stripped.so` (deploy as
`libteams.so`). Verified to compile & link for ARM (only the pre-existing `PURPLE_PLUGINS` warning).

## The three unknowns that need a captured call

1. **Codec + SDP dialect** — which `a=rtpmap` payloads NGC actually offers (want G.722; avoid
   Satin). Decides Δ3.
2. **Key placement** — is the SRTP master in the SDP `a=crypto` line, only in `udpKey.sessionKey`,
   or both? Decides the Δ1 parse.
3. **MS-TURN auth** — does stock libnice TURN allocate against the `:3478` relay with the MRAS
   `ticket`, or do we need a small MS-TURN client? The single biggest risk; decides Δ4.

All three are answered by one real call — the capture harness already logs everything needed.

## Morning runway

**0. Already staged on device:** the built calling plugin is at
`/media/internal/libteams-calling.so` (md5 `d6e0f557…`), ready to swap in. To activate WITH the
user (so messaging is re-verified immediately):
```
BP=/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2
cp $BP/libteams.so /media/internal/libteams-messaging.bak   # back up the working plugin
cp /media/internal/libteams-calling.so $BP/libteams.so      # swap in the calling build
# restart imlibpurpletransport (it respawns) -> Teams re-logs in; then place/receive a Teams call
tail -f /media/internal/teams-call-capture.log
```
The live plugin + LS2 roles were deliberately NOT swapped/restarted overnight (unattended runtime
risk to working messaging; test calls need a person anyway).

**1. Deploy** (see `deploy-teams.sh` for the plugin; the role/service/manifest files deploy with the
account bits). Push `libteams-personal.stripped.so` → device `libteams.so`, install the two role
JSONs + the `.call.service`, merge the PHONE cap (already in the source manifest), restart
`imlibpurpletransport`.

**2. Capture a call.** With Teams logged in on the device, place a call **from another Teams client
to this account** (and, separately, try placing one from the device once outgoing is modeled). Then:
```
cat /media/internal/teams-call-capture.log   # the full raw callNotification: SDP blob, udpKey, links
cat /media/internal/teams-call.log           # the parsed summary + state transitions
```
Expected today: the call **rings the stock Phone app** (state pushed via the LS2 bridge), `reject`
works (POSTs the reject link), `answer` transitions state but has **no audio yet** (media is a stub).

**3. Finish media** using the capture + `media/TEAMS_MEDIA_ADAPTATION.md`:
   - Δ1 keying (base64 `sessionKey` → 30-byte AES-CM master) + Δ2 cipher (`aes-128-icm`/`hmac-sha1-80`)
     — mechanical, do first.
   - Δ3 codec (G.722 if offered) and Δ4 MS-TURN allocate — per what the capture shows.
   - Wire `teams_calling.c`'s `teams_media_start/stop` stubs to the `teams_media` process (IPC), and
     POST the produced SDP answer to `call->link_media_answer`.

## Not done / caveats

- **Media = no audio yet** (stubbed) — the honest state; it's the post-capture work.
- **Outgoing dial** is a documented stub — the NGC *create* flow isn't in the reverse-engineered
  data; capture an outgoing call to model it. Incoming answer/reject is wired.
- **The reject/answer HTTP POST shape + auth headers** are best-effort from Eion Robb's comments;
  confirm against the capture (marked `CONFIRM WITH CAPTURE` in `teams_calling.c`).
- Satin (the default 1:1 codec) is closed — we must get the answer to select G.722 or SILK.
