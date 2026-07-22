#!/usr/bin/env python3
"""
teams_decode.py - decode a Teams 1:1 web-call capture into concrete teamsm build inputs.

Feed it either/both of:
  * a chrome://webrtc-internals dump  ("Download the PeerConnection updates and stats data")
  * a DevTools HAR  ("Save all as HAR with content")

It prints:
  * SDP summary  - m-lines, codec PT->name annotated against the known sdp-ngc-0.5 map, crypto
                   (SDES a=crypto / DTLS fingerprint), ICE ufrag/pwd, rtcp-mux/ptime/x- attrs,
                   and every relay(TURN) candidate = the relays the call actually used.
  * HAR summary  - flightproxy ORIGINATE / answer / reject requests (method, templatized URL,
                   JSON body) and the MRAS/TURN ticket (udpKey/username/password/ttl).

Everything is a pure LOCAL parse - nothing is sent anywhere. Auth token *values* are redacted
in the HAR output (header names kept), so the report is safe to share; SDP/ICE carry no tokens.

Usage:
  teams_decode.py capture.har webrtc_internals_dump.txt      # order/extension-agnostic
  teams_decode.py --har capture.har --webrtc dump.txt
  teams_decode.py dump.txt                                   # just the SDP/ICE side
"""
import sys, os, json, re, argparse

# --- known Teams sdp-ngc-0.5 payload-type map (from the APK teardown) ---------------------------
KNOWN_PT = {
    109: "SATINFB", 108: "SATIN", 104: "SILK/16000 (WB)", 103: "SILK/8000 (NB)",
    102: "opus", 9: "G722", 111: "SIREN", 18: "G729", 0: "PCMU/G711u", 8: "PCMA/G711a",
    13: "CN", 118: "CN", 119: "CN", 120: "CN", 101: "telephone-event (DTMF)",
}
# what the TouchPad can realistically do (mediastreamer/gst have these)
TOUCHPAD_OK = {104, 103, 9, 0, 8, 13, 101}
SENSITIVE_HEADERS = {"authorization", "x-skypetoken", "x-skype-token", "cookie",
                     "set-cookie", "x-ms-client-request-id", "sec-ch-ua"}
GUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
SIG_HINTS = ("flightproxy", "trouter", "mras", "relay.microsoft", "/calling/", "callmanager",
             "originate", "mediaanswer", "/answer", "/reject", "/decline", "/call/", "callcontroller")
TURN_KEYS = ("udpKey", "turn", "username", "password", "realm", "expires", "ttl",
             "relayAddress", "token", "iceServers", "urls", "credential", "mras")


def hr(t=""):
    print("\n" + "=" * 78)
    if t:
        print(t)
        print("=" * 78)


# ------------------------------------------------------------------ SDP / webrtc-internals -------
def _walk_strings(obj, path=""):
    """Yield (path, str) for every string leaf in a nested json structure."""
    if isinstance(obj, str):
        yield path, obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield from _walk_strings(v, f"{path}/{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _walk_strings(v, f"{path}[{i}]")


def extract_sdps(raw_text):
    """Find every SDP blob in a webrtc-internals dump (json) or raw text. Robust to Chrome
    version differences: an SDP always starts with 'v=0' and runs to the end of its string value."""
    sdps = []          # list of (label, sdp_text)
    candidates = []    # trickle 'candidate:...' lines seen outside SDP
    strings = []
    try:
        strings = list(_walk_strings(json.loads(raw_text)))
    except Exception:
        strings = [("", raw_text)]   # not json - treat whole file as one blob
    seen = set()
    for path, s in strings:
        s2 = s.replace("\\r\\n", "\r\n").replace("\\n", "\n")
        idx = s2.find("v=0")
        if idx != -1 and "\n" in s2[idx:idx + 8]:
            sdp = s2[idx:].strip()
            key = sdp[:120]
            if key not in seen:
                seen.add(key)
                label = path.split("/")[-1] or "sdp"
                # hint local vs remote from the surrounding key name
                low = path.lower()
                if "remote" in low:
                    label = "REMOTE (peer) " + label
                elif "local" in low:
                    label = "LOCAL (us) " + label
                sdps.append((label, sdp))
        for m in re.finditer(r"candidate:[^\"'\\\r\n]+", s2):
            candidates.append(m.group(0))
    return sdps, candidates


def parse_candidate(line):
    # a=candidate:FOUND COMP tcp/udp PRIO IP PORT typ TYPE [raddr IP rport PORT]
    p = line.replace("a=candidate:", "candidate:").split()
    if len(p) < 8 or p[0].split(":")[0] != "candidate":
        return None
    d = {"component": p[1], "transport": p[2], "priority": p[3], "ip": p[4], "port": p[5]}
    if "typ" in p:
        d["type"] = p[p.index("typ") + 1]
    if "raddr" in p:
        d["raddr"] = p[p.index("raddr") + 1]
        d["rport"] = p[p.index("rport") + 1]
    return d


def summarize_sdp(label, sdp):
    hr(f"SDP  [{label}]")
    media = None
    codecs, cryptos, cands = {}, [], []
    ufrag = pwd = fp = setup = ptime = None
    flags = []
    for ln in sdp.splitlines():
        ln = ln.strip()
        if ln.startswith("m="):
            media = ln[2:]
            print(f"  m= {media}")
        elif ln.startswith("a=rtpmap:"):
            body = ln[len("a=rtpmap:"):]
            pt = int(body.split()[0]); name = body.split()[1]
            codecs[pt] = name
        elif ln.startswith("a=crypto:"):
            # a=crypto:TAG SUITE inline:KEY... -> keep suite, redact key
            parts = ln[len("a=crypto:"):].split()
            suite = parts[1] if len(parts) > 1 else "?"
            cryptos.append(suite)
        elif ln.startswith("a=fingerprint:"):
            fp = ln[len("a=fingerprint:"):].split()[0]
        elif ln.startswith("a=setup:"):
            setup = ln[len("a=setup:"):]
        elif ln.startswith("a=ice-ufrag:"):
            ufrag = ln[len("a=ice-ufrag:"):]
        elif ln.startswith("a=ice-pwd:"):
            pwd = ln[len("a=ice-pwd:"):]
        elif ln.startswith("a=ptime:"):
            ptime = ln[len("a=ptime:"):]
        elif ln.startswith("a=rtcp-mux"):
            flags.append("rtcp-mux")
        elif ln.startswith(("a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive")):
            flags.append(ln[2:])
        elif ln.startswith("a=candidate:") or ln.startswith("candidate:"):
            c = parse_candidate(ln)
            if c:
                cands.append(c)
        elif ln.startswith("a=x-"):
            flags.append(ln[2:])
    print("  codecs (PT -> negotiated | known-Teams | TouchPad?):")
    for pt in sorted(codecs):
        known = KNOWN_PT.get(pt, "?")
        ok = "yes" if pt in TOUCHPAD_OK else "no/skip"
        print(f"    {pt:<4} {codecs[pt]:<22} | {known:<20} | {ok}")
    print(f"  keying:  SDES a=crypto suites={cryptos or 'none'}   "
          f"DTLS fingerprint={'yes ('+fp+')' if fp else 'no'}  setup={setup}")
    print(f"           -> media stack must do: "
          f"{'SDES-SRTP' if cryptos else ''}{' + ' if cryptos and fp else ''}{'DTLS-SRTP' if fp else ''}")
    print(f"  ICE:     ufrag={ufrag}  pwd={'<'+str(len(pwd))+' chars>' if pwd else None}")
    print(f"  flags:   {', '.join(flags) or 'none'}   ptime={ptime}")
    relays = [c for c in cands if c.get("type") == "relay"]
    if cands:
        print(f"  candidates: {len(cands)} total, {len(relays)} relay(TURN)")
        for c in relays:
            print(f"    RELAY {c['transport']} {c['ip']}:{c['port']}  "
                  f"(via {c.get('raddr','?')}:{c.get('rport','?')})  <- TURN relay used")


def do_webrtc(path):
    hr(f"### WEBRTC-INTERNALS  {os.path.basename(path)}")
    raw = open(path, "r", errors="replace").read()
    sdps, loose = extract_sdps(raw)
    if not sdps:
        print("  (no SDP found - is this the right dump? it should contain 'v=0' offer/answer)")
    for label, sdp in sdps:
        summarize_sdp(label, sdp)
    loose_relay = [parse_candidate(c) for c in loose]
    loose_relay = [c for c in loose_relay if c and c.get("type") == "relay"]
    if loose_relay:
        hr("Trickled RELAY (TURN) candidates seen outside SDP")
        for c in loose_relay:
            print(f"  RELAY {c['transport']} {c['ip']}:{c['port']} (via {c.get('raddr','?')}:{c.get('rport','?')})")


# ------------------------------------------------------------------------------ HAR --------------
def templatize(url):
    url = GUID_RE.sub("{guid}", url)
    url = re.sub(r"(?<=/)\d{6,}(?=/|$|\?)", "{id}", url)
    return url


def redact_headers(headers):
    out = []
    for h in headers:
        n = h.get("name", ""); v = h.get("value", "")
        if n.lower() in SENSITIVE_HEADERS:
            out.append(f"{n}: <REDACTED len={len(v)}>")
        elif n.lower() in ("host", "content-type", "accept", "x-ms-scenario-id",
                            "ms-cv", "x-ms-client-version", "user-agent", "origin",
                            "x-ms-client-request-id"):
            out.append(f"{n}: {v}")
    return out


def pretty_body(text, limit=4000):
    if not text:
        return "(empty)"
    try:
        return json.dumps(json.loads(text), indent=2)[:limit]
    except Exception:
        return text[:limit]


def scan_turn(text):
    if not text:
        return None
    low = text.lower()
    if not any(k.lower() in low for k in TURN_KEYS):
        return None
    try:
        j = json.loads(text)
        keep = {k: v for k, v in _flatten(j) if any(t.lower() in k.lower() for t in TURN_KEYS)}
        return keep or None
    except Exception:
        # not json: grep the interesting lines
        return {"raw_hits": [l for l in text.splitlines()
                             if any(t.lower() in l.lower() for t in TURN_KEYS)][:20]}


def _flatten(obj, pre=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _flatten(v, f"{pre}.{k}" if pre else k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _flatten(v, f"{pre}[{i}]")
    else:
        yield pre, obj


def do_har(path):
    hr(f"### HAR  {os.path.basename(path)}")
    har = json.load(open(path, "r", errors="replace"))
    entries = har.get("log", {}).get("entries", [])
    print(f"  {len(entries)} requests total")
    interesting, turn_hits = [], []
    for e in entries:
        req = e.get("request", {}); resp = e.get("response", {})
        url = req.get("url", "")
        low = url.lower()
        if not any(h in low for h in SIG_HINTS):
            # still scan the response body for a TURN ticket even if url isn't obviously signaling
            body = resp.get("content", {}).get("text", "")
            t = scan_turn(body)
            if t:
                turn_hits.append((url, t))
            continue
        interesting.append(e)
        body = resp.get("content", {}).get("text", "")
        t = scan_turn(body) or scan_turn(req.get("postData", {}).get("text", ""))
        if t:
            turn_hits.append((url, t))

    hr(f"Call-signaling requests ({len(interesting)})")
    for e in interesting:
        req = e.get("request", {}); resp = e.get("response", {})
        print("\n  --------------------------------------------------------------")
        print(f"  {req.get('method')}  {templatize(req.get('url',''))}")
        print(f"  status: {resp.get('status')} {resp.get('statusText','')}")
        rh = redact_headers(req.get("headers", []))
        if rh:
            print("  req headers:"); [print("    " + h) for h in rh]
        pd = req.get("postData", {}).get("text")
        if pd:
            print("  req body:")
            for l in pretty_body(pd).splitlines():
                print("    " + l)
        rb = resp.get("content", {}).get("text")
        if rb:
            print("  resp body:")
            for l in pretty_body(rb, 2000).splitlines():
                print("    " + l)

    hr(f"TURN / MRAS ticket candidates ({len(turn_hits)})")
    if not turn_hits:
        print("  (none spotted - the MRAS/relay request may be under a host not in SIG_HINTS;")
        print("   if the SDP had relay candidates but nothing shows here, grep the HAR for the")
        print("   relay IP or 'udpKey'/'username' and add that host to SIG_HINTS)")
    for url, t in turn_hits:
        print(f"\n  from {templatize(url)}")
        if isinstance(t, dict):
            for k, v in t.items():
                sv = str(v)
                if any(s in k.lower() for s in ("password", "credential", "token", "udpkey", "key")):
                    sv = f"<REDACTED len={len(sv)}>"
                print(f"    {k} = {sv[:200]}")


# ------------------------------------------------------------------------------ main -------------
def classify(path):
    if path.lower().endswith(".har"):
        return "har"
    try:
        head = open(path, "r", errors="replace").read(4096)
        if '"log"' in head and '"entries"' in head:
            return "har"
    except Exception:
        pass
    return "webrtc"


def main():
    ap = argparse.ArgumentParser(description="Decode a Teams web-call capture for teamsm.")
    ap.add_argument("files", nargs="*", help="capture.har and/or webrtc dump (auto-detected)")
    ap.add_argument("--har"); ap.add_argument("--webrtc")
    a = ap.parse_args()
    har = a.har; webrtc = a.webrtc
    for f in a.files:
        if classify(f) == "har":
            har = f
        else:
            webrtc = f
    if not har and not webrtc:
        ap.print_help(); sys.exit(1)
    print("Teams call capture decoder - local parse only, tokens redacted.")
    if webrtc:
        do_webrtc(webrtc)
    if har:
        do_har(har)
    hr("NEXT")
    print("  Hand this report back. From it we lock: the codec subset for the gst media engine,")
    print("  SDES-vs-DTLS keying, the flightproxy ORIGINATE/answer/reject request templates, and")
    print("  the MRAS->TURN credential derivation - the three gaps for teamsm.")


if __name__ == "__main__":
    main()
