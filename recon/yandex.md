# Yandex Disk — recon

**Verdict: VIABLE — BUILT & VERIFIED.** Well-documented REST API (`cloud-api.yandex.net/v1/disk`),
OAuth2, still open in 2026. Built as a DOCUMENTS **and PHOTO.UPLOAD** connector (`yandex/`).
Credentialed with a registered OAuth app and verified end-to-end against the live API (OAuth incl.
refresh, identity, docs up/download, photo folder-create/upload, `system_folders.photostream`
album resolution + Pictures fallback, per-photo signed links). Only on-device sign-in is untested.

## Why it fits
- Plain REST/JSON over HTTPS → bundled curl, same transport as the others.
- **Path-based locators** (`disk:/folder/file.docx`) — the same model as Dropbox, so the
  QuickOffice reroute maps cleanly with **no** opaque-ID filename recovery needed.
- Overwrite is a first-class flag (`overwrite=true`), so save-back/edit is trivial.

## Auth
- Authorize: `https://oauth.yandex.com/authorize?response_type=code&client_id=…&redirect_uri=…`
- Token: `POST https://oauth.yandex.com/token` (`grant_type=authorization_code&code=&client_id=&client_secret=`) → `{access_token, refresh_token, expires_in}`
- **Ships a client_secret**, but the connector also always sends an S256 **PKCE** challenge, so a
  public/PKCE build works too. Refresh-on-401 via `grant_type=refresh_token`.
- API auth header is `Authorization: OAuth <token>` (Yandex convention — **not** `Bearer`).

## Endpoints used
| Op | Call |
|---|---|
| list | `GET /resources?path=disk:/FOLDER&limit=200` → `_embedded.items[]` (`name`, `type` dir/file, `path`, `size`, `modified`, `mime_type`) |
| download | `GET /resources/download?path=` → `{href}` → GET href (unauthenticated, signed) |
| upload | `GET /resources/upload?path=DEST&overwrite=true` → `{href, method:PUT}` → PUT file to href |
| replace | same as upload with `overwrite=true` (no id needed) |
| identity | `GET https://login.yandex.ru/info?format=json` → `default_email`/`login`/`real_name` |

## Notes / uncertainties
- `Authorization: OAuth` header form and the `login.yandex.ru/info` identity fields are Yandex's
  long-standing conventions but weren't quoted verbatim in the fetched docs this pass — worth a
  live confirm on first real sign-in.
- First 200 items per folder (no paging), matching the other connectors.

## To activate
Register an app at `oauth.yandex.com`, grant it Disk read/write scope, set the redirect URI, drop
`CLIENT_ID` + `CLIENT_SECRET` into `yandex/service/com.palm.service.yandexdisk/config.js`.
