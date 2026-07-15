# Instagram — RE recon / feasibility (live API, 2026-07)

**webOS connector wanted:** PHOTO.UPLOAD (no files/DOCUMENTS angle exists).
**Method:** current-API review against our hard constraints (modern-curl transport, PKCE
public client, one unprovisioned package for every device).

## Verdict: 🔴 DEAD — not built.

The blocker is the **auth + account model**, not the transport. Curl-downloading the bytes
would actually work; the OAuth/account model is fundamentally incompatible with our
"one unprovisioned package ships to every device" design, and there is no personal-account
photo API left at all.

## Evidence

- **Basic Display API — permanently shut down 2024-12-04** (announced 2024-09-04, 90-day
  window). It was the *only* consumer/personal-account photo API; all its endpoints now error.
- **Successors don't serve personal accounts.** The "Instagram API with Instagram Login" and the
  Instagram Graph API both require a **Business/Creator (professional)** account connected to a
  Facebook Page. A normal personal Instagram cannot be read.
- **Confidential client — `client_secret` is MANDATORY.** Meta's token exchange (code→token and
  short→long-lived) requires the app secret, explicitly "never in client-side code or an app
  binary that could be decompiled." We'd have to embed a shared secret in every TouchPad — the
  exact confidential-client problem our design forbids.
- **App Review + business verification** gate any real use beyond a handful of hand-added
  "Instagram Testers." Individual hobbyist approval for personal-photo sync is not realistic.
- **Media URLs (the one thing that works):** `media_url` returns plain HTTPS
  `scontent.cdninstagram.com` GETs curl can fetch unauthenticated — but they are **short-lived
  signed URLs** (hours–days). Fine for our download-now aggregator, moot given the auth wall.

## Mapping to our capabilities

PHOTO.UPLOAD is the only relevant capability; Instagram has no files angle. It is blocked three
independent ways — dead personal-account API, mandatory `client_secret`, and the App-Review gate.

## Recommendation

**Do not attempt Instagram.** The Dropbox/Box/OneDrive PKCE public-client pattern cannot be
reused here. If another photo source is wanted, pick one that offers a **PKCE public client**
(OneDrive Camera Roll — already built — or a Flickr-style API) rather than anything behind Meta's
confidential-client + App-Review wall.

Sources (2026-07): Basic Display deprecation notices (Behold, Smash Balloon, WPZOOM), Meta
`instagram-platform/reference/access_token`, media-URL-expiry threads.
