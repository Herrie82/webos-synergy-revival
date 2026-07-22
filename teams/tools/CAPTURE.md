# Teams 1:1 call capture — checklist (desktop web client, no Android, no MITM)

Capture ONE real 1:1 Teams **audio** call in the Chrome/Edge web client, then run `teams_decode.py`
on the two saved files. This fills the 3 remaining gaps for the `teamsm` build:

1. flightproxy **ORIGINATE** URL template + JSON envelope (place an outgoing call)
2. exact **answer / reject** request line(s)
3. **MRAS udpKey → TURN** username/HMAC derivation ([MS-TURN]/[MS-ICE2]) + the TURN server list

Everything else (sdp-ngc-0.5 grammar, codec PT map, crypto suites) is already recovered from the APK
teardown — this capture confirms it live and pins the signaling envelopes.

---

## Step by step in Chrome (or Edge)

Must be **Chrome or Edge** (Chromium) — Firefox has no `webrtc-internals`. On Edge use `edge://webrtc-internals`.

**Setup**
1. Open Chrome. In **tab 1**, go to **https://teams.live.com** (personal account — that's what `purple-teams`
   authenticates; work = https://teams.microsoft.com) and sign in. Have a second person/account ready for a
   1:1 **audio** call.
2. Open a **new tab (tab 2)** → **`chrome://webrtc-internals`** and leave it open. It only records connections
   created *while it is already open*, so open it **before** the call.

**Arm the network capture**
3. Back on **tab 1 (Teams)** → press **F12** → **Network** tab.
4. Tick **"Preserve log"**. Leave DevTools open.

**Make the call**
5. In Teams, place a **1:1 audio call**. Let it **connect and stay up ~15–20 s** (talk a little so media flows),
   then **hang up**.

**Save the two files**
6. Switch to **tab 2 (`chrome://webrtc-internals`)**. An `RTCPeerConnection` entry appears. At the top click
   **"Download the PeerConnection updates and stats data"** → saves a `.txt`. *(No tokens — safe to share.)*
7. Back on **tab 1 → DevTools → Network** → right-click the request list → **"Save all as HAR with content"**
   → saves a `.har`.

**⚠ Privacy — the HAR carries live auth tokens**
8. The `.har` includes your `Authorization` / `X-Skypetoken` / cookies. After handing it over (or after running
   the decoder), **sign out of the Teams web session** so those tokens die (they're short-lived anyway, ~24 h).
   Or strip the header **values** for `Authorization` / `X-Skypetoken` / `Cookie` first — the decoder only needs
   URL templates + JSON shapes, not token strings. (The webrtc-internals `.txt` has no tokens.)

---

## Decode it

```
python3 teams/tools/teams_decode.py <dump>.txt <capture>.har
```
(order/extension-agnostic; pass just one file to decode only that side). It prints:
- **SDP summary** — codecs annotated against the known Teams PT map + whether the TouchPad can do each
  (SILK NB/WB, G.722, G.711, CN, DTMF), the keying mode (**SDES `a=crypto`** vs DTLS), ICE ufrag/pwd,
  rtcp-mux/ptime/x- attrs, and every **relay (TURN)** candidate actually used.
- **HAR summary** — the flightproxy **ORIGINATE / answer / reject** requests (method, templatized URL, JSON
  body) and the **MRAS/TURN ticket** (udpKey/username/password/ttl). Token values are redacted in the output.

Either run it yourself and paste the report, or hand back the two raw files and I'll run it.

---

## What happens next

From the report we lock:
- the codec subset for the GStreamer media engine,
- SDES-vs-DTLS keying (expect SDES `AES_CM_128_HMAC_SHA1_80` — standard SRTP, so **interoperable**, unlike Signal),
- the flightproxy ORIGINATE/answer/reject request **templates**,
- the MRAS → TURN credential derivation.

Then we build `teamsm` = `purple-teams` core (auth + Trouter + incoming-offer decode, already done) +
a GStreamer SILK/G.722 media engine + the proven `wacallm` Luna/audiod/stock-dialer shell.

## Fallback
If teams.live.com / teams.microsoft.com won't place a call in your browser (rare on Chrome/Edge), stop and say
so — we pivot to the **work-account SIP / Teams Direct Routing** route (robust, standards-based, no capture).
