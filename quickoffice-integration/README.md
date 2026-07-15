# QuickOffice integration

Repairs QuickOffice's broken remote-file support by rerouting it onto our modern
`com.palm.service.dropbox`. A Dropbox account's documents list and open in QuickOffice's
native viewer again — no native reversing required.

## What was broken (reverse-engineering result)

QuickOffice **never talked to Box/Dropbox directly.** Every remote operation went through
Quickoffice's own proxy gateway — **`https://g1.quickofficeconnect.com/`** (proprietary "MX"
API v1.4.1) — which Google decommissioned after acquiring Quickoffice in 2012. Compounding it:

- File bytes were transferred by `palm://com.palm.downloadmanager/` (OpenSSL 0.9.8 — no
  modern TLS).
- Auth was a **plaintext password** sent to the dead proxy as `login[0]/login[1]`; Box/Dropbox
  are OAuth-only now.

The entire fetch path is **readable JS/Enyo** (`RemoteFileService.js`); the native ARM engine
(`arxservice`) is only the document *renderer* and runs *after* the file is already on local
disk — it never touches the network. So the fix is pure JS.

## The reroute (`patches/RemoteFileService.js.patch`)

Two seams in `RemoteFileService.js`, both keyed on the account's mxId `"drop"` (Dropbox):

| Kind / method | Original | Rerouted to |
|---|---|---|
| `RemoteFileService.getFiles` (`_modernList`) | MX `serviceLogin → GetRoot → GetFilesForAccountAtLocation` | `palm://com.palm.service.dropbox/listFolder {accountId, path}` → maps entries → existing `_processFiles` |
| `RemoteFileCacheService.getFilePathToRemoteFile` (`_modernDownload`) | `getDownloadUrl` + `dlManager.call({method:"download"})` | `.../downloadFile {accountId, dropboxPath, localPath}` |
| `RemoteFileUploadService.replaceFileInCloud` (`_modernReplace` → `_modernUpload`) | MX `GetRemoteItemInfo` (out-of-sync check) + `dlManager.call({method:"upload"})` to the dead proxy | `.../uploadFile {accountId, localPath, dropboxPath}` (mode `overwrite`) → existing `successCb` |
| `RemoteFileUploadService.addFileInCloud` (`_modernUpload`) | `getAddFileUrl` + `dlManager` upload | `.../uploadFile` to `parent + "/" + name` |

**Save-back (edit → Save) now works:** `replaceFileInCloud` is what QuickOffice calls when you
save an edited cloud document. The modern path uploads the cached local copy
(`uniqueTargetFilename`) back to its Dropbox path (`localInfo.uri`) with `mode:"overwrite"`, then
fires QuickOffice's existing `successCb` and updates `remoteFileInfoCache` — so the editor's
"saved" state is unchanged. The dead MX out-of-sync round-trip is skipped (Dropbox's overwrite is
last-writer-wins).

**Bug fixed in the same patch:** the earlier revision added the `modernDbx` `PalmService`
component only to `RemoteFileUploadService`, but `_modernDownload` lives in
`RemoteFileCacheService` and calls `this.$.modernDbx` — which didn't exist there, so the Dropbox
**download** path would have thrown once exercised (it was never interactively tested). The
component is now present in all three kinds that use it (list / download / upload).

Each adds a `PalmService` component (`modernDbx`) to its enyo kind and re-fires QuickOffice's
**existing** success contract, so the downstream "open local file → hand to native arx viewer"
path is untouched:

- List entries map `{path→uri, name, size, modified→lastmodified, folder→"application/directory"}`
  and feed `_processFiles` verbatim.
- Download writes to the exact cache path QuickOffice expects —
  `QOWT.MXConfig.downloadFolder + QOWT.MX.createUniqueTargetFilename(name)` =
  `/media/internal/.qo/<timestamp>-<name>` — then fires
  `successCb(uniqueTargetFilename, name, accountInfo, mimeType)`. The mime is derived via
  `QOWT.MX.getMimeType(ext)` (with an `application/octet-stream` fallback, because
  `downloadCB` calls `mimeType.toLowerCase()`).

**No account-recognition patch is needed:** QuickOffice maps accounts by
`loc_name.toLowerCase()`, and our `com.palm.dropbox` template's `loc_name` "Dropbox" already
falls into the existing `"dropbox" → mxId "drop"` case, carrying our `accountId` as `_id`.

## Companion service changes (in `../dropbox/`)

- `com.quickoffice.webos` / `com.quickoffice.ar` added to the `allowedAppIds` of
  `listFolder` / `downloadFile` / `uploadFile`.
- `downloadFile` now passes `curl --create-dirs` so it creates `/media/internal/.qo/` if absent.

## Applying

```sh
patch -p1 -d /media/cryptofs/apps/usr/palm/applications/com.quickoffice.webos < patches/RemoteFileService.js.patch
# restart LunaSysMgr so QuickOffice reloads its (cached) app JS
```

Round-trip verified: applying the patch to the pristine 2.1.2113 file reproduces the deployed
version exactly.

## Applying to the PDF app

`com.quickoffice.ar`'s `source/RemoteFileService.js` is **byte-identical** to
`com.quickoffice.webos`'s (verified against both 2.1.2113 / 10.3.484 IPKs), so the **same patch
applies to both** — just point `patch -d` at the `com.quickoffice.ar` app dir as well.

## TODO

- **Other backends:** the reroute is keyed on `mxId === "drop"` (Dropbox) only. Box/OneDrive/Drive
  each expose the same `listFolder`/`downloadFile`/`uploadFile` contract, but QuickOffice's
  `FileStore` must first map their `loc_name` to an `mxId`; Box was an original QuickOffice
  provider (`"box"`), OneDrive/Drive would need a new mapping.
- **Interactive on-device test** of list / open / **save-back** is still pending.
