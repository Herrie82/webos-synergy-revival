# LinkedIn (com.linkedin.android 4.1.x) — RE recon

**webOS connector needed:** CONTACTS.

## What the APK shows
- App drives the **private Voyager API**: `www.linkedin.com/voyager/api/...` (also GraphQL).
- Auth is **web-session cookies**, not OAuth: `li_at` (session token) + `JSESSIONID` +
  `Csrf-Token` header. No OAuth client_id/redirect anywhere for member data.

## Feasibility of a private-API connector
- The public LinkedIn API (v2 / "Sign In with LinkedIn") exposes **only the authenticated
  member's own profile + email** and share/marketing scopes. The **connections/contacts API was
  shut to third parties in 2015** — there is no sanctioned way to download connections.
- Voyager *can* be driven by harvesting a logged-in browser's `li_at` cookie and replaying it
  with the CSRF header, but that is:
  - **fragile** — endpoints/traversal change without notice;
  - **cookie-bound** — no refresh; the user must re-paste `li_at` when it expires;
  - **bannable** — explicitly against the LinkedIn UA/TOS; accounts get flagged for automation.

## Verdict
**Not revivable** as a real connector. Only a fragile, TOS-violating `li_at` scraper is
technically possible — not worth wiring into Synergy. Recommend: delete.
