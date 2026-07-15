# OneDrive connector

A full Microsoft **OneDrive** (Microsoft Graph) **DOCUMENTS + PHOTO.UPLOAD** connector,
built to the same architecture as Dropbox/Box. Code-complete; **untested on device** only
because it needs an Azure app `client_id` (see Configuration).

Of the three cloud providers investigated, OneDrive was the **cleanest fit** — a public
PKCE client with *no secret*, personal Microsoft accounts allowed, and a file-download
endpoint that 302-redirects to a pre-signed URL our curl fetches with no auth header.

## What's here

```
service/com.palm.service.onedrive/   node service: OAuth2/PKCE + Microsoft Graph
  oauth2.js        Microsoft identity v2.0, public-client PKCE (never sends a secret);
                   scope on both code-exchange and refresh (Graph requires it)
  graphapi.js      Graph REST: /me/drive/{root|items/{id}}/children, /content (302),
                   PUT raw-body upload, transparent refresh-on-401
  httpcurl.js      shells all TLS to the bundled modern curl (dataFile = raw-body PUT)
  creds.js acl.js  credentials-by-accountId; allowedAppIds enforcement
  commands/        getAuthorizeUrl, exchangeCode, checkCredentials,
                   listFolder, downloadFile, uploadFile,           <- DOCUMENTS
                   photolib, listAlbums, listPhotos                <- PHOTO.UPLOAD (Camera Roll)
apps/
  com.palm.app.onedrive-auth/    customUI OAuth login (Atlas simple-mode, stateless PKCE verifier)
  com.palm.app.onedrive-files/   Enyo file browser/uploader (folder-ID breadcrumb stack)
account/com.palm.onedrive.json   Synergy template: customUI validator, DOCUMENTS + PHOTO.UPLOAD,
                                 permissions for the auth app + both services
```

## How it differs from Box (both are REST/ID-based)

| | Box | OneDrive (Graph) |
|---|---|---|
| Item tree | `/folders/{id}/items` | `/me/drive/{root\|items/{id}}/children` (URL segments) |
| Root sentinel | `"0"` | `"root"` |
| List envelope | `{entries:[…]}` | `{value:[…]}`; folder vs file = `folder`/`file` facet |
| Download | `/content` → 302 dl.boxcloud.com | `/content` → 302 pre-signed (curl strips auth on cross-host redirect) |
| Upload | multipart to upload.box.com | **PUT raw body** to `…:/{name}:/content` |
| Photo `src_big` | `/content?access_token=` | item `@microsoft.graph.downloadUrl` (pre-signed, inline in the listing) |
| Secret | optional | **never** — MS public clients redeem the code with no secret |
| Refresh token | rotates (~60d) | rotates (90-day sliding) — persist the new one each call |

The service accepts a generic `path` locator (= item ID; `"root"`/empty = drive root) so the
file-picker and a future QuickOffice reroute call it Dropbox-uniformly.

## Configuration (required before it can run)

Register a free app in the **Azure portal → App registrations**:
- **Supported account types:** *Accounts in any org directory **and** personal Microsoft accounts* (so consumer OneDrive works).
- **Platform:** *Mobile and desktop applications*; add redirect URI `http://localhost/onedrive/oauth2callback` verbatim.
- **Authentication → Allow public client flows: Yes.**
- Copy the **Application (client) ID** into `service/com.palm.service.onedrive/config.js` (`CLIENT_ID`). **No client_secret** — leave the placeholder; `oauth2.js` runs pure PKCE.

Same modern-curl (`/var/dropbox-tls/`) + current-CA prerequisites as Dropbox.

## Status / caveats

- ✅ Service, both apps, template, Photos-aggregator `case "com.palm.onedrive"` (in
  [`../photos-integration/patches/Utils.js.patch`](../photos-integration/patches/Utils.js.patch)).
- ⏳ **Account sign-in untested** — needs a real `client_id`.
- ⚠️ **Consent screen:** an unverified hobbyist app shows a one-time "this app hasn't been
  verified" notice the user accepts. Not a blocker; publisher verification is optional.
- ⚠️ **Photos:** only the **Camera Roll** special folder is surfaced (Graph has no album
  model), and only for accounts that have one; it degrades to an empty album otherwise.
- ⏳ **QuickOffice OneDrive reroute** — could mirror the Dropbox `mxId` branch, but Graph is a
  new provider QuickOffice never knew, so it needs a new `mxId` mapping first (larger than the
  Box case). Not done.
