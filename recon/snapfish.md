# Snapfish (com.snapfish.mobile 17.11.x) — RE recon (static, from APK)

**webOS connector needed:** PHOTO.UPLOAD.
**Tooling:** unzip + strings + grep on the 8 dex + resources.arsc + assets (no jadx/apktool).

## Architecture recovered

### 1. Dynamic service discovery (the entry point)
- Single bootstrap URL: **`https://discovery.snapfish.com/v2/endpoints/`**
- Returns the live base URLs for the named services below (nothing else is hardcoded — that's
  why the dex has no upload host literal). The client caches these and routes every call through them.

### 2. Services named in the client (discovery keys)
| Service | dex refs | Role |
|---|---|---|
| `DataStoreService`  | 93 | core asset/photo store (metadata, albums, assets) |
| `IdentityService` / `AuthService` | 13+6 | login / token |
| `UploadService`     | 13 | dedicated binary upload endpoint |
| `MediaService`      | 6  | media serving |
| `assetrenderer` → `/assetrenderer/v2/` | — | render/thumbnail |

Asset model paths seen: `/assets`, `/Asset`, `/assetId/`, `AssetResponse`, `AssetHashesSrEvent`
(client uploads by content hash → then commits the asset).

### 3. Identity — two layers
- **Snapfish OAuth2**: `/oauth2`, `/token`, `/authorize`, `grant_type`, `client_id`,
  `client_secret`, `refresh_token`. Plus federated `/oauth/google/token`, `/oauth/openid/keys/`.
- **AWS Cognito**: `AWSCognitoIdentityService`, `cognito-identity.<region>.amazonaws.com`
  (bundled AWS SDK — the full region list is the SDK's table, not necessarily the prod region).
  Cognito almost certainly issues the temporary creds used to PUT asset bytes (likely S3-backed
  UploadService).

## The blocker: credentials are NOT in cleartext
- The dex/resources contain the field *names* (`client_id`, `client_secret`, `api_key`, `app_key`)
  but **no attributable plaintext values**. The only concrete keys in resources are Google/Firebase/
  Zendesk (`google_api_key`, `default_web_client_id`, `sf_zendesk_config_clientId`) — not Snapfish's.
- Candidate GUIDs exist (`092c1883-b512-434d-8e51-0ac2162b7206`, `1380b3fc-…`, `43b1109d-…`, etc.)
  but cannot be attributed to client_id vs analytics vs Cognito app without decompiling call sites.
- So Snapfish's own OAuth client_id/secret + api_key are obfuscated / assembled at runtime /
  possibly in the native `.so` (split_config.arm64_v8a) or fetched server-side.

## Verdict
**Feasible in principle, but static RE has hit its ceiling.** We recovered the full endpoint
architecture and auth model, but *not* the secrets or the exact upload request (headers, multipart
shape, hash/commit sequence, any request signing / Cognito assume-identity). Those cannot be
finished from static analysis because they're deliberately not in cleartext.

## To unblock — one live capture session
Run the Android app through **mitmproxy** (device with the Snapfish app + user account) and record:
1. `GET discovery.snapfish.com/v2/endpoints/` → note the resolved `UploadService`/`DataStoreService`/
   `IdentityService` base URLs.
2. **Login** (email/password) → capture the OAuth2 `/token` request+response: the `client_id`,
   `client_secret`/`api_key` header (likely `X-Api-Key` or a query param), `grant_type`, and the
   returned `access_token`/`refresh_token` (+ any Cognito `IdentityId`/AWS creds exchange).
3. **Upload one photo** → capture: asset-hash check, the PUT/POST to `UploadService` (headers,
   auth, multipart vs raw bytes, any `Content-MD5`/signature), then the DataStore "commit asset".

From that capture I can build `com.palm.service.photos.snapfish` (node) behind the existing
`PHOTO.UPLOAD` capability — reusing the shared `com.palm.service.photos` plumbing — with:
`discover → oauth token (+refresh) → hash → upload → commit`.

## Static avenues left (lower ROI than the capture)
- `strings` the native lib in `split_config.arm64_v8a.apk` for the api_key/client_secret.
- Install `jadx`/`apktool` on the host to decompile the OAuth/Upload call sites and attribute the GUIDs.

## Legal/robustness note
No public developer program → this is an **unofficial, TOS-violating** integration and can break on
any Snapfish server change. Fine for a personal TouchPad revival; do not ship/redistribute.
