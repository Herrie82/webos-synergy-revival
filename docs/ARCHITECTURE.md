# Architecture

How the revived connectors work on a 2011 device talking to 2026 cloud APIs.

## 1. The TLS wall — and how everything routes around it

The device `node` (`/usr/palm/nodejs/node`) links **OpenSSL 0.9.8k**, and the stock webview
is WebKit ~2009. Neither can negotiate TLS 1.2/1.3, so **no modern HTTPS can happen in the
webOS JS/node layer** — the exact wall the Teams port hit. Modern TLS exists on the device
only via a **bundled curl** (curl 7.88.1 / OpenSSL 1.1.1w, TLS 1.3) at `/var/dropbox-tls/`.

Consequences, applied consistently:

- **Login UI** → runs in **Atlas** (`org.webosports.app.atlas`, a WPE browser with modern
  TLS), launched in "simple mode". The stock account webview never touches Dropbox.
- **Token / API / file transfers** → the service shells out to the bundled curl via
  `child_process` (`httpcurl.js`). The JS layer is pure orchestration.
- **Photo downloads** (in the stock Photos aggregator) → the one plain-HTTP downloader is
  patched to shell out to the same curl.

Every curl invocation needs `LD_LIBRARY_PATH=/var/dropbox-tls` (its bundled
`libssl.so.1.1` / `libcrypto.so.1.1` / `libcurl.so.4`) and `--cacert
/etc/ssl/certs/ca-certificates.crt`.

### Current CA roots are a deployment prerequisite

The stock rootfs ships a **2011** `/etc/ssl/certs/ca-certificates.crt` with no modern roots
(e.g. ISRG Root X1), so a flashed/reset device can't verify Dropbox's cert. Rather than
bundle a private `cacert.pem`, a current CA bundle is installed into the **system store** (a
prerequisite the connector already needs for the curl). Verified: `ssl_verify_result=0`
against `api.dropboxapi.com` using only the system store.

## 2. Auth = public client + PKCE (no secret, distributable)

A confidential client_secret can't ship in a distributed image (extractable, and revoking it
breaks every device), so sign-in is a **public client using PKCE** (RFC 7636), like modern
mobile apps:

- `oauth2.buildAuthorizeUrl()` generates a random `code_verifier` (`crypto.randomBytes(32)`
  → base64url) and sends its `S256` `code_challenge` in the authorize URL.
- `exchangeCode()` sends the `code_verifier` (not a secret) to redeem the `?code=`.
- `refresh()` uses `client_id` + `refresh_token`.

Nothing is provisioned per-device; the app key is public. PKCE needs SHA-256 —
`foundations.crypto` only has SHA-1, so node's core `crypto` is used (0.9.8k supports
`sha256`/`randomBytes`); fall back to shelling `/usr/bin/openssl` if a build lacks node
`crypto`.

**Stateless verifier.** The on-demand service is idle-killed during the (long) web login, so
the `code_verifier` cannot live in service memory. `getAuthorizeUrl` returns it, the auth app
carries it through the login, and `exchangeCode` receives it back.

## 3. The account-add flow

```
Settings → Add Dropbox
  → customUI app com.palm.app.dropbox-auth
      getAuthorizeUrl ──> {url, codeVerifier}
      launch Atlas {mode:simple, url, oauthRedirectPrefix, oauthResultKey}
      Atlas (WPE) renders Dropbox login, captures the ?code= redirect
        into a com.palm.systemservice preference
      auth app polls getPreferences until the pref carries code=
      exchangeCode {code, codeVerifier} ──service──curl──> token endpoint
  → service returns {returnValue, username(email), credentials:{common:{access,refresh,expiresAt}}}
  → Accounts stores it; createAccount runs under the AUTH APP's appId
```

Gotchas that were real bugs:

- The **accounts service caches all templates in RAM at startup** and only reloads when the
  template *list* changes — editing template *content* requires killing the accounts service
  (`ice.accounts.js`) so it re-reads disk, then restarting LunaSysMgr.
- **Locale overrides win.** A template is `base + resources/<locale>/<id>.json`, and the
  locale file's keys override the base. Every change must be mirrored into all locale files.
- The **auth app must be in `read`+`writePermissions`** (createAccount is permission-checked
  against the caller's appId), and **`exchangeCode` must return a username**.
- Resolve a Mojo command's future **only inside the `.then`** — `future.nest(inner)` leaks
  the inner's raw result before the wrapper runs.
- **Atlas must cold-launch.** Relaunching a stale Atlas card doesn't re-navigate, so the
  redirect is never captured — close any running Atlas card first.

## 4. Credentials by accountId

Consumer apps never handle tokens. They pass an `accountId`; the service resolves credentials
itself via `readCredentials {accountId, name:"common"}` and persists rotated refresh tokens
via `writeCredentials`. This requires `com.palm.service.dropbox` in the template's
`read`+`writePermissions`. Tokens rotate on refresh — always persist the new one.

## 5. Access control

The mojoservice framework does not enforce a command's `allowedAppIds`; `acl.js` adds it,
mirroring `com.palm.service.accounts` (caller = `message.applicationID() ||
senderServiceName()`, glob-matched, process-suffix stripped). App-facing methods are gated to
their consumer appId. **Service-to-service calls carry no bus identity** — the Photos
aggregator reaches provider methods with an empty caller, indistinguishable from a shell call,
so `listAlbums`/`listPhotos` are left open (matching the stock facebook/photobucket providers)
and rely on the LS2 private-bus role.

## 6. Photos: a MojoDB-driven cloud source

The Photos app never loads a remote URL — it renders local files out of MojoDB. The backend
aggregator `com.palm.service.photos` discovers `PHOTO.UPLOAD` accounts, calls a per-provider
`listAlbums`/`listPhotos` (provider name is a **hardcoded** `templateId`-switch in the
aggregator's `Utils.js`, not derived), downloads every photo to
`/media/internal/.photosApp/…`, and writes the album/file DB records the app reads.

We host the provider methods **inside the Dropbox service** (already bus-registered) instead
of a separate `com.palm.service.photos.dropbox` — avoiding a new LS2 role and bus rescan. The
only edits to stock code are the two patches in `photos-integration/`: the `Utils.js`
templateId case, and swapping the aggregator's plain-HTTP image downloader for the modern
curl. See [`../photos-integration/README.md`](../photos-integration/README.md).

## 7. Why QuickOffice is a dead end

The stock Dropbox/Box connectors only ever *validated credentials* (old password API); the
actual file browsing was done by **QuickOffice**, a closed app whose ARM engine (`arxservice`)
is just the Adobe PDF/DRM renderer — no Box/Dropbox client, and its `RemoteFileService` routes
through `com.palm.downloadmanager` (dead v1 URLs + OpenSSL 0.9.8 → "no internet connection").
It can't be rebuilt or reused. So the revived connectors **do file I/O themselves** in the
node service and are consumed by a new file-picker app (and the Photos app), never QuickOffice.
