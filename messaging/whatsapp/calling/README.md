# WhatsApp calling on webOS — stock Phone app integration

Native WhatsApp **voice calling** driven by the unmodified webOS **Phone app** (`com.palm.app.phone`),
exactly the way legacy webOS did Skype: the phone's transport-agnostic `CallSynergizer` discovers
PHONE-capability accounts and routes call control (`dial`/`answer`/`disconnect`/`callStateQuery`) to a
mediator over luna-service2. We repurpose the **dead Skype PHONE slot** so no new dialer/in-call UI is
needed — the stock dialer, in-call screen, and Call Log all "just work".

WhatsApp VoIP itself is pure Go: [whatsmeow] + `meowcaller` (MLow codec, SRTP, STUN), packaged as the
`wacallm` mediator.

## Architecture

```
  Phone app (com.palm.app.phone)              wacallm mediator                WhatsApp
  ┌──────────────────────────────┐     LS2   ┌───────────────────┐   whatsmeow ┌─────────┐
  │ DialProxy  ── picks transport │──────────▶│ com.palm.whatsapp │────────────▶│  VoIP   │
  │ CallSynergizer ── dial/answer │◀─────────▶│  dial/answer/     │◀────────────│ (MLow,  │
  │   /disconnect /callStateQuery │  callState│  disconnect/…     │   audiod    │  SRTP)  │
  │ CallLogView/SubItems ── log   │           │  + ALSA voip pcm  │◀───────────▶└─────────┘
  └──────────────────────────────┘           └───────────────────┘  loudspeaker
```

Three moving parts:

1. **wacallm mediator** — an always-on LS2 service that owns the bus name `com.palm.whatsapp` and
   implements the UI-facing call contract (`dial`, `answer`, `disconnect`, `hangupAll*`, `hold`, `swap`,
   `merge`, `dtmf`, `changeMedia`, and the `callStateQuery` subscription). It bridges call audio through
   ALSA `voip`/`voipsource` (→ PulseAudio `pvoip`) and drives `audiod` (`CallStatusUpdate` +
   `setCurrentScenario phone_back_speaker`, i.e. loudspeaker — the TouchPad tablet has no earpiece).
2. **Phone-app patches** — this directory (`app-patches/com.palm.app.phone/`). Full patched files; see
   below.
3. **Account** — the WhatsApp account must advertise the **PHONE** capability so `CallSynergizer`
   discovers it (see "Account").

## Phone-app patches (`app-patches/com.palm.app.phone/`)

| File | Change |
|------|--------|
| `source/CallSynergizer.js` | `TRANSPORTS.SKYPE = "com.palm.whatsapp"` (repurpose the dead Skype slot). `resubscribe: true` on the `callStateQuery` subscription so it survives mediator restarts (webOS only auto-resubscribed for the TIL transport). |
| `source/DialProxy.js` | Detect the WhatsApp account by `templateId === "com.palm.whatsapp"`; manual dials with no paired phone route to the WhatsApp transport. |
| `phoneApp/source/AppMenu.js` | Hide "Check Skype Credit". |
| `source/utils/Utils.js` | New `Utils.callNetworkName(service)` — the **single** place that names the VoIP transport in the UI (returns "WhatsApp" for the slot today; extend here for Telegram/Signal). |
| `phoneApp/source/CallLogView.js` | Call-log list rows show the network via `callNetworkName` and format numbers instead of hardcoding "Skype". |
| `phoneApp/source/SubItems.js` | Call-detail drawer shows `callNetworkName`; WhatsApp numbers now go through `FormatPhoneNumber` (they're always phone numbers, so no more raw `+31…`). |
| `phoneApp/source/styles-overrides.css` | Fixed-width network column in the call-detail drawer so longer names (WHATSAPP/TELEGRAM/SIGNAL) don't overlap the number. |
| `resources/en.json` | Skype→WhatsApp string overrides. |

### Adding another network later (Telegram, Signal, …)

All UI naming funnels through **`Utils.callNetworkName(service)`** — that's the one seam to touch. Today
every VoIP call shares the single repurposed Skype PHONE slot, so the call-log record only knows
`service = com.palm.whatsapp`. To distinguish networks, either give each its own PHONE
account/template (branch on `templateId` in `callNetworkName`) or have the mediator tag each call with a
network name stored in the call-log record and return that.

## Install

```sh
# 1. phone-app patches (this dir): remount rw, push 8 files, restart LunaSysMgr
./deploy-calling.sh

# 2. mediator: build-output/wacallm-luna must be installed + running with its LS2 role/.service
#    owning com.palm.whatsapp (see "Mediator" — source recovery pending, TODO below).

# 3. account: grant the WhatsApp account the PHONE capability (once), e.g.:
luna-send -n 1 palm://com.palm.service.accounts/modifyAccount '{
  "accountId":"<your-whatsapp-accountId>",
  "object":{"capabilityProviders":[
    {"id":"com.palm.whatsapp.im"},
    {"id":"com.palm.whatsapp.contacts"},
    {"id":"com.palm.whatsapp.call"}
  ]}}'
```

Verify: `luna-send -n 1 palm://com.palm.service.accounts/listAccounts '{"capability":"PHONE"}'` returns a
`com.palm.whatsapp` provider, and `luna-send -n 1 -f palm://com.palm.whatsapp/callStateQuery
'{"subscribe":true}'` streams call state.

## Mediator (`wacallm`) — ⚠ source recovery pending

The built mediator is `build-output/wacallm-luna` (armv7, ~20 MB; `build-output/` is `.gitignore`d). It's a
Go `c-archive` (whatsmeow + meowcaller + modernc SQLite, build tag `lunaarchive`) linked with a C
luna-service2 wrapper (`svc/main.c`) that also does the ALSA/audiod bridge.

**Known gap:** the wacallm *source* (`luna_archive.go`, `svc/main.c`, `build-wacallm-luna.sh`) is **not
currently present on the build host or in this repo** — only the compiled binary survives. It must be
recovered or reconstructed before the mediator can be rebuilt. Tracked as a TODO.

[whatsmeow]: https://github.com/tulir/whatsmeow
