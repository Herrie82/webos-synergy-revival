# Yandex Disk connector

A **Yandex Disk** (`cloud-api.yandex.net/v1/disk`) **DOCUMENTS-only** Synergy connector,
built to the same architecture as the Dropbox/OneDrive connectors. Code-complete;
**untested on device** — it needs a Yandex OAuth app `client_id` (+ `client_secret`, see
Configuration).

Yandex Disk is **path-based like Dropbox** — a resource is a real path
(`disk:/Documents/foo.docx`), not an opaque item id — so this connector is a near-clone of
Dropbox, and the uniform consumer contract maps cleanly (no opaque-id filename recovery).

## What's here

```
service/com.palm.service.yandexdisk/   node service: OAuth2 + Yandex Disk REST v1
  config.js        OAuth (oauth.yandex.com) + REST (cloud-api.yandex.net/v1/disk) endpoints;
                   CLIENT_ID + CLIENT_SECRET placeholders; disk.read/write/info + login scopes
  oauth2.js        Authorization Code + PKCE; sends client_secret when configured (confidential),
                   else pure PKCE (public). No `scope` on the token calls (Yandex fixes it at authorize)
  yandexapi.js     Disk REST: /resources listing, /resources/download + /resources/upload
                   two-step signed-href flow, uploadReplace (overwrite=true), refresh-on-401.
                   Uses "Authorization: OAuth <token>" (NOT Bearer)
  httpcurl.js      shells all TLS to the bundled modern curl (identical invocation; -L follow
                   for the download/upload signed hrefs; dataFile = raw-body PUT upload)
  creds.js acl.js  credentials-by-accountId; allowedAppIds enforcement
  commands/        getAuthorizeUrl, exchangeCode, checkCredentials,
                   listFolder, downloadFile, uploadFile              <- DOCUMENTS only
apps/
  com.palm.app.yandexdisk-auth/    customUI OAuth login (Atlas simple-mode, stateless PKCE verifier)
  com.palm.app.yandexdisk-files/   Enyo file browser/uploader (path breadcrumb)
account/com.palm.yandexdisk.json   Synergy template: customUI validator, DOCUMENTS capability,
                                   permissions for the auth app + the service
account/images/                    32x32 / 48x48 icons (PLACEHOLDERS — rebrand for Yandex)
```

Icons under `apps/*/icon.png` and `account/images/*` are **placeholders copied from the
Dropbox connector** — replace them with Yandex Disk artwork before shipping.

## Identifiers

- Bus/service name: **`com.palm.service.yandexdisk`**
- Account templateId: **`com.palm.yandexdisk`**
- QuickOffice reroute mxId: **`yandex`** (the integrator wires the reroute; this connector
  only provides the service methods it calls)

## How the API is used (web-verified July 2026)

| Operation | Endpoint |
|---|---|
| Authorize | `GET https://oauth.yandex.com/authorize?response_type=code&client_id=…&redirect_uri=…&scope=…&code_challenge=…&code_challenge_method=S256` |
| Token | `POST https://oauth.yandex.com/token` — `grant_type=authorization_code&code=&client_id=&client_secret=&code_verifier=` → `{access_token, refresh_token, expires_in}` |
| Refresh | same token endpoint, `grant_type=refresh_token&refresh_token=` |
| Identity | `GET https://login.yandex.ru/info?format=json` → `{login, default_email, real_name}` (for `username`) |
| List | `GET /v1/disk/resources?path=disk:/FOLDER&limit=200` → `_embedded.items[]` `{name, type("dir"\|"file"), path, size, modified, mime_type}` |
| Download | `GET /v1/disk/resources/download?path=…` → `{href, method}`; then GET `href` (signed, no auth) to disk |
| Upload | `GET /v1/disk/resources/upload?path=DEST&overwrite=true` → `{href, method:"PUT"}`; then PUT the file to `href` (signed, no auth) |

All authenticated Disk/identity requests send **`Authorization: OAuth <access_token>`**.
`type:"dir"` maps to the uniform `"folder"`; files map to their `mime_type` (or `"file"`).

## Uniform consumer contract

- `listFolder {accountId, path}` → `{entries:[{type, name, path, size, modified}]}`
  (`path` is a `disk:/…` locator; `""`/`"/"`/`"disk:/"` = root)
- `downloadFile {accountId, path|dropboxPath, localPath}`
- `uploadFile {accountId, localPath, path | folderId, name, replace}` — a full `path` wins;
  otherwise `folderId`+`name` are joined. **Replace = overwrite** (path-based), which is also
  the create-default, so `replace` never needs an item id.

## Configuration (required before it can run)

Register a free app at **https://oauth.yandex.com/client/new**:
- **Redirect URI:** add `http://localhost/yandex/oauth2callback` verbatim.
- **Permissions (scopes):** Yandex.Disk REST API — *Read* + *Write* + *Info*; plus
  *Access to email address* and *Access to username* (so `exchangeCode` can fetch the email).
- Copy the **ID** into `service/com.palm.service.yandexdisk/config.js` `CLIENT_ID`, and the
  **Password/secret** into `CLIENT_SECRET`.
  - To run as a **public (PKCE-only) client** instead, leave `CLIENT_SECRET` as the
    `PLACEHOLDER…` default — `oauth2.js` then never sends a secret (it still sends the S256
    challenge). Whether Yandex accepts a secret-less exchange depends on the app type chosen.

Same modern-curl (`/var/dropbox-tls/`) + current-CA prerequisites as Dropbox/OneDrive.

## Status / caveats

- ✅ Service, both apps, template — all `node --check` clean.
- ⏳ **Account sign-in untested** — needs a real `client_id`/`client_secret`.
- ⚠️ **Icons are placeholders** (copied from Dropbox) — rebrand before shipping.
- ⚠️ **List paging:** only the first `limit=200` items per folder are returned (no `offset`
  paging yet) — matches the other connectors' single-page behaviour.
- ⚠️ **Signed-href auth:** the download/upload hrefs are treated as self-authenticating
  (fetched with no OAuth header), per Yandex docs ("you don't need an OAuth token to
  upload"). `-L` follow is enabled in case the download href 302-redirects to a storage host.
- ⏳ **QuickOffice reroute (mxId `yandex`)** — provided by the integrator; not in this dir.
