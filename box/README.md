# Box connector (scaffold)

A partial Box (`box.com`) DOCUMENTS connector — the same architecture as Dropbox but not yet
finished or tested on device.

## What's here

- `service/com.palm.service.boxnet/` — node service scaffold: `oauth2.js`, `boxapi.js`
  (REST v2, `GET /folders/{id}/items`, transparent refresh-on-401), and
  `commands/{exchangeCode,checkCredentials,listFolder}`.
- `account/com.palm.boxnet.json` — Synergy template with a customUI OAuth2 validator
  (replacing the dead password validator), DOCUMENTS capability repointed off QuickOffice.

Box is RESTful where Dropbox is RPC — otherwise the two mirror each other closely.

## To finish it, apply the Dropbox stack

The Dropbox connector is the reference implementation. Port each proven piece over:

1. **Migrate to PKCE** — this scaffold still assumes a client_secret. Public-client + PKCE
   (see `dropbox/service/com.palm.service.dropbox/oauth2.js`) so nothing secret ships.
2. **Build `com.palm.app.boxnet-auth`** — mirror `com.palm.app.dropbox-auth` (Atlas
   simple-mode login, stateless PKCE verifier, poll the systemservice pref).
3. **Template fixes** — customUI validator in the base **and every locale override**; add
   the auth app + `com.palm.service.boxnet` to `read`+`writePermissions`; make `exchangeCode`
   return a username.
4. **Commands** — add `acl.js`, `creds.js` (credentials-by-accountId), `getAuthorizeUrl`,
   `uploadFile`/`downloadFile`, and drop the `future.nest()` anti-pattern (resolve the future
   only inside the `.then`).
5. **Files app** — mirror `com.palm.app.dropbox-files`.
6. **Photos** (optional) — the [`../photos-integration`](../photos-integration) 4-point
   recipe: template `PHOTO.UPLOAD` block, a `case "com.palm.boxnet"` in the aggregator
   `Utils.js`, `listAlbums`/`listPhotos` in the service, reuse the same `Sync-Manager` curl
   patch.

## Configuration

Register a Box app at <https://app.box.com/developers/console> (Custom App → OAuth 2.0, add
the redirect URI) and fill `service/com.palm.service.boxnet/config.js`. Same modern-curl +
current-CA prerequisites as Dropbox.
