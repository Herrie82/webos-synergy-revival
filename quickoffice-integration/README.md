# QuickOffice integration

Repairs QuickOffice's broken remote-file support by rerouting it onto our modern cloud
services — **Dropbox, Box, OneDrive, and Google Drive**. Those accounts' documents list,
open, edit, and **save back** in QuickOffice's native viewer again — no native reversing
required.

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

Three seams in `RemoteFileService.js`. Each is now **service-agnostic**: a `_modernSvc(mxId)`
helper (added to all three kinds) maps the account's mxId → the right revival `PalmService`
component (`modernDbx`/`modernBox`/`modernOne`/`modernGdrive`), or `null` to fall through to the
legacy MX path. All four backends expose the same `listFolder`/`downloadFile`/`uploadFile`
contract, so one code path serves them all.

| Kind / method | Original | Rerouted to |
|---|---|---|
| `RemoteFileService.getFiles` (`_modernList`) | MX `serviceLogin → GetRoot → GetFilesForAccountAtLocation` | `…/listFolder {accountId, path}` → maps entries → existing `_processFiles` |
| `RemoteFileCacheService.getFilePathToRemoteFile` (`_modernDownload`) | `getDownloadUrl` + `dlManager.call({method:"download"})` | `…/downloadFile {accountId, dropboxPath, localPath}` |
| `RemoteFileUploadService.replaceFileInCloud` (`_modernReplace` → `_modernUpload`) | MX `GetRemoteItemInfo` (out-of-sync check) + `dlManager` upload to the dead proxy | `…/uploadFile {accountId, localPath, fileId, replace:true}` → existing `successCb` |
| `RemoteFileUploadService.addFileInCloud` (`_modernUpload`) | `getAddFileUrl` + `dlManager` upload | `…/uploadFile {accountId, localPath, folderId, name}` |

**Save-back (edit → Save) works** across all four services. `replaceFileInCloud` uploads the
cached local copy (`uniqueTargetFilename`) back over the existing remote file and fires
QuickOffice's existing `successCb` + cache update, so the editor's "saved" state is unchanged. The
dead MX out-of-sync round-trip is skipped. Each backend overwrites differently — the shared
`{fileId, replace:true}` (plus `dropboxPath` for Dropbox) lets each service pick its own path:
Dropbox `mode:"overwrite"`, Box/OneDrive/Drive a *new-version / update-content-by-id* call.

**Path vs. ID locators.** Dropbox's locator is a real path (ends in the filename). Box, OneDrive
and Drive use **opaque IDs**, so `_modernDownload` couldn't name the cached file (no extension →
the native viewer can't pick a renderer). Fixed with a small `QOWT.mxRevivalNames` map that the
list step fills (`locator → real filename`) and the download step reads. Downstream is untouched:
the file still lands at `QOWT.MXConfig.downloadFolder + createUniqueTargetFilename(name)` and fires
`successCb(unique, name, account, mime)`.

**Bug fixed in the same patch:** an earlier revision added the `modernDbx` component only to
`RemoteFileUploadService`, but `_modernDownload` lives in `RemoteFileCacheService` and calls
`this.$.modernDbx` — which didn't exist there, so the download path would have thrown once
exercised (it was never interactively tested). The components are now present in all three kinds.

## Account recognition (`patches/FileStore.js.patch`)

QuickOffice maps accounts by `loc_name.toLowerCase()` in `FileStore.addUpdateAccountCallback`.
Dropbox already matched (`"dropbox" → mxId "drop"`), but the others didn't, so a small second
patch adds the cases:

| Template `loc_name` | → mxId |
|---|---|
| `Dropbox` | `drop` (stock case, unchanged) |
| `Box` | `box` (new `case "box"`; stock only had `"box.net"`) |
| `OneDrive` | `onedrive` (new literal mxId) |
| `Google Drive` | `gdrive` (new literal mxId) |

`accountType` is inert for the new ones — the modern reroute bypasses all MX account-type logic.

## Companion service changes

Each service's `listFolder`/`downloadFile`/`uploadFile` lists `com.quickoffice.webos` /
`com.quickoffice.ar` in `allowedAppIds`, and `downloadFile` passes `curl --create-dirs` so
`/media/internal/.qo/` is created if absent. For **save-back**, each service gained an
overwrite-by-id path: Dropbox `mode:"overwrite"`, Box `uploadNewVersion`, OneDrive
`uploadReplace` (PUT item content), Drive `uploadReplace` (PATCH content).

## Applying

Both patches apply to **both** apps (`com.quickoffice.webos` and `com.quickoffice.ar` —
their `RemoteFileService.js` and `FileStore.js` are byte-identical, verified against the 2.1.2113
/ 10.3.484 IPKs):

```sh
for app in com.quickoffice.webos com.quickoffice.ar; do
  d=/media/cryptofs/apps/usr/palm/applications/$app
  patch -p1 -d "$d" < patches/RemoteFileService.js.patch
  patch -p1 -d "$d" < patches/FileStore.js.patch
done
# restart LunaSysMgr so QuickOffice reloads its (cached) app JS
```

Both patches are **round-trip verified**: applying to the pristine IPK source reproduces the
patched file exactly.

## Limitations / TODO

- **Google Drive native docs** (Docs/Sheets/Slides) won't open via QuickOffice: they have no
  downloadable bytes and the download seam doesn't pass an `exportMime`. Real Office files stored
  in Drive open fine. (The stand-alone `gdrive-files` app *does* export native docs.)
- **Interactive on-device test** of list / open / **save-back** for all four backends is pending.
