# webOS Synergy Revival

Reviving the defunct **Synergy** cloud connectors on the HP TouchPad (webOS 3.0.5,
`nova-cust-image-topaz`). The stock connectors died with their backends (old APIs,
2009-era TLS, closed helper apps). This repo modernizes them: OAuth2/PKCE account
sign-in, modern-TLS transport, and real file/photo I/O — decoupled from the dead
QuickOffice engine.

## Status

| Connector | What works | State |
|---|---|---|
| **Dropbox** | Account sign-in (OAuth2 + PKCE), file browse/upload/download (file-picker app), **and photos in the stock Photos app** | ✅ **complete, verified end-to-end on device** |
| **QuickOffice** | Remote file **list + open** rerouted onto our Dropbox service (dead MX proxy bypassed) | ✅ patched (patch, JS-only) |
| **Box** | Full stack — sign-in (OAuth2 + PKCE), file browse/upload/download, auth + file-picker apps, and photos provider | 🟡 **code-complete, mirrors Dropbox** — untested pending a Box `client_id` |
| Facebook / LinkedIn | — | ❌ dead (private APIs, perms revoked); recon only |
| Snapfish | — | ⚠️ marginal (private OAuth gateway); recon only |

Everything under `dropbox/` has been built and **run on real hardware**: an account is
created and survives reboots; files browse/upload/download byte-exact; and a Dropbox
folder appears as an album in the Photos app with images synced down through the modern
curl.

## The one hard constraint (shapes the whole design)

The device `node` runtime is **OpenSSL 0.9.8k** and the stock webview is WebKit ~2009 —
**neither can complete a TLS 1.2/1.3 handshake**, so *no modern HTTPS can happen in the
webOS JS/node layer*. Every modern-TLS step is therefore pushed out of JS:

- **The login page** runs in **Atlas** (WPE browser, modern TLS) — not the stock webview.
- **All token/API/file calls** shell out to a **bundled modern curl** (curl 7.88.1 /
  OpenSSL 1.1.1w, TLS 1.3) at `/var/dropbox-tls/curl`.
- **Auth is a public client + PKCE** (RFC 7636) — there is **no client_secret** anywhere,
  so the identical package ships to every device with nothing to provision.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full picture.

## Layout

```
dropbox/
  service/com.palm.service.dropbox/   OAuth2 + API v2 service (sign-in, files, photos provider)
  apps/com.palm.app.dropbox-auth/     customUI OAuth webview (drives Atlas login)
  apps/com.palm.app.dropbox-files/    Enyo file-picker/manager consumer app
  account/com.palm.dropbox/           Synergy account template (base + 7 locale overrides)
photos-integration/
  patches/                            2 patches to the stock com.palm.service.photos
  README.md                           the 4-point recipe to add any cloud photo source
quickoffice-integration/
  patches/RemoteFileService.js.patch  reroute QuickOffice's remote-file layer onto our service
  README.md
box/
  service/com.palm.service.boxnet/    Box service (OAuth2/PKCE + REST v2, files + photos)
  apps/com.palm.app.boxnet-auth/      customUI OAuth login
  apps/com.palm.app.boxnet-files/     Enyo file-picker/manager (folder-ID breadcrumb)
  account/com.palm.boxnet.json        Synergy template (DOCUMENTS + PHOTO.UPLOAD)
recon/                                RE notes: facebook, linkedin, snapfish
docs/ARCHITECTURE.md
```

## Deployment prerequisites

This connector depends on two things being present on-device (from the companion
`OpenSSL-11-Update` / deployment-bundle work — **not** committed here):

1. **The modern-TLS curl bundle** at `/var/dropbox-tls/` (`curl` + `libssl.so.1.1` +
   `libcrypto.so.1.1` + `libcurl.so.4`). All HTTPS shells out to this.
2. **A current CA store** at `/etc/ssl/certs/ca-certificates.crt`. The stock rootfs ships
   a 2011 stub with no modern roots (e.g. ISRG Root X1), so a flashed/reset device can't
   verify Dropbox's cert until this is refreshed.

With those in place, deploy `dropbox/` into `/usr/palm/…`, apply the `photos-integration/`
patches, restart the accounts + photos services, and sign in via Settings → Accounts →
Dropbox. Per-component READMEs have the details.

## License / attribution

Original Palm/HP account-service and Photos-app code is **not** vendored here — the Photos
changes ship as **patches** against the stock files. Everything under `dropbox/`,
`box/service/`, and the templates is new work.
