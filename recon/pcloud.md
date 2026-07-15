# pCloud — recon

**Verdict: VIABLE.** Clean public REST API, still fully open in 2026, OAuth2 authorization-code
flow. Built as a full DOCUMENTS + PHOTO.UPLOAD connector (`pcloud/`). Untested pending a pCloud
app `client_id` + `client_secret`.

## Why it fits
- Ordinary REST/JSON over HTTPS → rides the bundled modern curl exactly like Dropbox/OneDrive.
- OAuth2 (no device-side password), long-lived tokens (no refresh dance).
- Numeric folder/file IDs (root `folderid=0`) — same locator model as Box/OneDrive, so the
  QuickOffice reroute's `mxRevivalNames` filename-recovery path applies unchanged.

## The one real quirk: data-region host
pCloud accounts live in **US** (`api.pcloud.com`) or **EU** (`eapi.pcloud.com`) regions. The OAuth
redirect returns `hostname` + `locationid` (1 = US, 2 = EU) telling you which API host to use for
that account. The connector stores the resolved host in the credentials (`common.apiHost`) and
uses it for every subsequent call. An EU account hitting the US host fails, so this must be right.

## Auth
- Authorize: `https://my.pcloud.com/oauth2/authorize?client_id=…&response_type=code&redirect_uri=…`
- Token: `https://<apihost>/oauth2_token?client_id=…&client_secret=…&code=…` → `{access_token, userid, locationid}`
- **Ships a client_secret** (like the Drive connector; pCloud has no PKCE public-client mode).
- `access_token` is passed as a query param on every method call (pCloud SDK convention), not a Bearer header.

## Endpoints used
| Op | Call |
|---|---|
| list | `GET /listfolder?folderid=0` → `metadata.contents[]` (`name`, `isfolder`, `folderid`/`fileid`, `size`, `modified`) |
| download | `GET /getfilelink?fileid=…` → `{hosts[], path}` → fetch `https://hosts[0]+path` |
| upload | `POST /uploadfile?folderid=…&filename=…&nopartial=1` (multipart) |
| replace | `GET /checksumfile?fileid=` → name+parentfolderid, then re-upload same name (overwrites; old kept as revision) |
| photos | no album API → one folder (root) surfaced as one album; `src_big` = per-image `getfilelink` temp URL |
| identity | `GET /userinfo` → `email` |

## To activate
Register an app at the pCloud developer console, set the redirect URI the auth app expects, drop
`CLIENT_ID` + `CLIENT_SECRET` into `pcloud/service/com.palm.service.pcloud/config.js`.
