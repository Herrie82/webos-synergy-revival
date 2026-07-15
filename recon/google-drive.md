# Google Drive — RE recon / feasibility (live API, 2026-07)

**webOS connector wanted:** DOCUMENTS (and, hoped, PHOTO.UPLOAD).
**Method:** current-API review against our hard constraints (modern-curl transport, PKCE
public client, one unprovisioned package for every device).

## Verdict

- **DOCUMENTS: 🟡 MARGINAL** — technically a clean clone of the Dropbox/Box stack; the wall is
  Google's *scope + verification policy*, not the TouchPad. Buildable as a **personal /
  ≤100-user, unverified** connector; **not** publicly shippable without CASA/app verification.
  → **We built it anyway** under that limitation. See [`../gdrive/`](../gdrive/).
- **PHOTO.UPLOAD: 🔴 DEAD** — not built. Drive stopped syncing Google Photos years ago; the
  separate Photos Library API (since **2025-03-31**) only returns *app-created* media, and
  browsing a user's existing library now requires the interactive **Picker API** — not
  curl-fetchable URLs. There is no headless "list my photos → download bytes" path.

## What fits our architecture (the good parts)

- **File download is a perfect fit.** `GET https://www.googleapis.com/drive/v3/files/{id}?alt=media`
  streams the raw bytes with an `Authorization: Bearer` header — exactly our bundled-curl model.
  Google-native docs (Docs/Sheets/Slides, `application/vnd.google-apps.*`) aren't binary and use
  `GET /files/{id}/export?mimeType=…` instead (also plain GET + Bearer); our connector picks an
  export target (docx/xlsx/pptx/pdf) per native type.
- **Listing** is query-based, not a path tree: `GET /files?q='{folderId}' in parents and
  trashed=false&fields=files(id,name,mimeType,size,modifiedTime)`. Root alias id = `"root"`. A
  folder is `mimeType application/vnd.google-apps.folder`. Maps cleanly to our entry shape.
- **PKCE works** for the "Desktop app" client type (loopback redirect still allowed for Desktop,
  deprecated only for Android/iOS/Chrome types).

## The blockers (why it isn't shippable)

1. **A `client_secret` is FORCED.** Even the "Desktop app" (installed/public) client type still
   requires the secret on the token exchange — Google just officially treats it as
   non-confidential. Net: we ship one bundled secret in every package. Tolerable for a personal
   build, but it violates our "nothing to provision / no secret" preference, and new desktop
   clients (since 2025-06) only let you download the secret once at creation.
2. **The scope trade-off is the real killer.** `drive.file` is non-sensitive (no warning screen)
   but only sees files the app *created* or the user picked via Google Picker — it **cannot list
   arbitrary folders**, so it can't back a generic file picker. Browsing the user's Drive needs
   `drive.readonly` or `drive` — both **RESTRICTED** scopes.
3. **Restricted scopes = heavy verification.** Manual review, category limits, and server-side
   data handling triggers a **CASA Tier 2 security assessment** ($0 self-serve up to ~$75k).
   Unverified, you get the scary "unverified app" screen and a hard **100-user lifetime cap**
   that can never be reset.
4. **Refresh-token 7-day trap.** While the OAuth consent screen is in **Testing**, external
   refresh tokens are revoked every 7 days (`invalid_grant`). Durable tokens require flipping the
   app to **"In production"** — which for restricted scopes drops you into the verification
   gauntlet. Production tokens then last until ~6 months idle.

## Shippability call

- **Personal / hobbyist (≤100 users):** buildable today — restricted `drive` scope, unverified,
  accept the warning screen, keep the app **"In production"** so tokens don't die at 7 days. This
  is what `../gdrive/` targets.
- **Public release:** effectively **DEAD** without CASA + verification. Do not redistribute a
  connector using a shared restricted-scope client.

## Notes for whoever configures it
- Register at <https://console.cloud.google.com/> → OAuth consent screen (External, **In
  production**) + Credentials → **OAuth client ID → Desktop app**. Add scope
  `.../auth/drive`. Paste `client_id` **and** `client_secret` into `gdrive/…/config.js`.
- The dead stock `com.palm.google` template's QuickOffice/Google-Docs proxy offers **nothing
  reusable** — this is a fresh DOCUMENTS provider mirroring Dropbox/Box.

Sources (2026-07): Drive `manage-downloads`, OAuth `native-app`, `restricted-scope-verification`,
unverified-app 100-user cap, Photos Picker/Library API updates.
