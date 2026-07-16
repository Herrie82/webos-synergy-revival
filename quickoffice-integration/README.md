# QuickOffice integration

Repairs QuickOffice's broken remote-file support by rerouting it onto our modern cloud
services — **Dropbox, Box, OneDrive, Google Drive, pCloud, and Yandex Disk**. Those accounts'
documents list, open, edit, and **save back** in QuickOffice's native viewer again — no native
reversing required. (Flickr is photos-only, so it isn't a QuickOffice provider.)

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
component (`modernDbx`/`modernBox`/`modernOne`/`modernGdrive`/`modernPcloud`/`modernYandex`), or `null` to fall through to the
legacy MX path. All six backends expose the same `listFolder`/`downloadFile`/`uploadFile`
contract, so one code path serves them all.

| Kind / method | Original | Rerouted to |
|---|---|---|
| `RemoteFileService.getFiles` (`_modernList`) | MX `serviceLogin → GetRoot → GetFilesForAccountAtLocation` | `…/listFolder {accountId, path}` → maps entries → existing `_processFiles` |
| `RemoteFileCacheService.getFilePathToRemoteFile` (`_modernDownload`) | `getDownloadUrl` + `dlManager.call({method:"download"})` | `…/downloadFile {accountId, dropboxPath, localPath}` |
| `RemoteFileUploadService.replaceFileInCloud` (`_modernReplace` → `_modernUpload`) | MX `GetRemoteItemInfo` (out-of-sync check) + `dlManager` upload to the dead proxy | `…/uploadFile {accountId, localPath, fileId, replace:true}` → existing `successCb` |
| `RemoteFileUploadService.addFileInCloud` (`_modernUpload`) | `getAddFileUrl` + `dlManager` upload | `…/uploadFile {accountId, localPath, folderId, name}` |

**Save-back (edit → Save) works** across all six services. `replaceFileInCloud` uploads the
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

## Listing reliability (found in first on-device test)

The first real device run surfaced two list bugs, both now fixed in `RemoteFileService.js.patch`:

- **Every entry appeared twice.** The picker calls `cancelAll()` + `getFiles()` *twice* per
  folder open; the legacy path relied on `cancelAll()` (`CancelRequestFromGroup`) to drop the
  first in-flight request so only one render happened. Our modern `PalmService` list calls
  weren't cancellable, so **both** completed and both rendered. `cancelAll()` now also calls
  `cancel()` on the six revival `PalmService` components (enyo `Service.cancel()` destroys its
  outstanding `Request` children) and bumps a list generation; `_modernListOk` drops any response
  whose stamped generation is stale. One render per open.
- **`Cannot set property 'ROOT' of undefined`** thrown on every list. `_processFiles()` writes
  `this.folderCache[…]`, which the legacy `_startFetching()` seeds but the modern reroute
  bypassed. `_modernList` now initializes `this.folderCache` first, so the throw (which left the
  `qowt:error` listener dangling) is gone.

## Auto-refresh after save (`FileStore.js.patch`)

Cloud services have no push "watch", so saving a new/edited file from the editor never fired the
local-file watch that refreshes the browser — newly-added files needed a manual refresh. Now
`_modernUploadOk` dispatches a `qowt:remoteFileChanged` document event on a successful upload, and
`FileStore` (which already holds the browser's watch callback via `setWatchCallback`) listens for
it and fires that callback — exactly the local-file-watch path. The open folder clears its cache
and re-lists through the always-fresh modern `getFiles`, so the saved file shows immediately.

**Crash fix (found in the second on-device test — `FolderContentsList.js.patch`).** The event is
broadcast to *every* `FileStore` instance, so it also fired `onWatchFired` on browsers that aren't
mounted (a closed Save-As dialog, or a list still mid-construction). That schedules a render which
runs in a **later tick** and hit `this.$.overlay.hide()` with no `overlay` subcomponent —
`Cannot call method 'hide' of undefined` — and because it threw in an async tick it couldn't be
caught at the fire site; it aborted the render turn and left the *real* Dropbox listing stuck on
its spinner. Two-part fix: `FileStore._onRemoteFileChanged` skips destroyed stores (and wraps the
call), and `FolderContentsList.showOverlay`/`hideOverlay` now no-op if their subcomponents are
absent (a torn-down/half-built list). This is a third patched file, stock-pristine otherwise.

## Manual refresh — pull-to-refresh + toolbar button (third on-device test)

The broadcast auto-refresh above only helps when a browser is *already open* during a change. But
you save from the **editor**, where no file browser is mounted — so a just-saved file only appears
when you next open the browser (which does re-list fresh). To make refreshing explicit and reliable,
two affordances were added:

- **Pull-to-refresh** (`FolderContentsList.js.patch`). The list's `VirtualList` scroll strategy
  reports `getScrollTop() < 0` **only** when it's over-pulled past the top (normal scrolling bottoms
  out at 0), so a negative scrollTop past a 60px threshold is an unambiguous "pull down at the top"
  signal — no fighting the strategy's own drag handling. Hooked via the list's published
  `onScroll`/`onScrollStop` (which `VirtualList` doesn't use internally): arm on `onScroll`, fire on
  release. It calls the new `refreshNow()` — drop `fsoCache`, reset paging, `scheduleRender(RESET)` —
  which re-queries through the always-fresh modern `getFiles`.
- **Toolbar Refresh button** (`FolderContentsPane.js.patch`, a fourth patched file). A captioned
  `ToolButton` on the **left** of the footer toolbar (opposite the New-document / Share buttons),
  wired to the same `refreshNow()`.

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
| `pCloud` | `pcloud` (new literal mxId; numeric-ID locators like Box/OneDrive) |
| `Yandex Disk` | `yandex` (new literal mxId; path locators like Dropbox) |

`accountType` is inert for the new ones — the modern reroute bypasses all MX account-type logic.

## Companion service changes

Each service's `listFolder`/`downloadFile`/`uploadFile` lists `com.quickoffice.webos` /
`com.quickoffice.ar` in `allowedAppIds`, and `downloadFile` passes `curl --create-dirs` so
`/media/internal/.qo/` is created if absent. For **save-back**, each service gained an
overwrite-by-id path: Dropbox `mode:"overwrite"`, Box `uploadNewVersion`, OneDrive
`uploadReplace` (PUT item content), Drive `uploadReplace` (PATCH content), pCloud same-name re-upload, Yandex `overwrite=true` PUT.

## Applying

All four patches apply to **both** apps (`com.quickoffice.webos` and `com.quickoffice.ar` — their
`RemoteFileService.js`, `FileStore.js`, `FolderContentsList.js` and `FolderContentsPane.js` are
byte-identical, verified against the 2.1.2113 / 10.3.484 IPKs):

```sh
for app in com.quickoffice.webos com.quickoffice.ar; do
  d=/media/cryptofs/apps/usr/palm/applications/$app
  patch -p1 -d "$d" < patches/RemoteFileService.js.patch
  patch -p1 -d "$d" < patches/FileStore.js.patch
  patch -p1 -d "$d" < patches/FolderContentsList.js.patch
  patch -p1 -d "$d" < patches/FolderContentsPane.js.patch
done
# restart LunaSysMgr so QuickOffice reloads its (cached) app JS
```

All four patches are **round-trip verified**: applying to the pristine IPK source reproduces the
patched file exactly.

## Limitations / TODO

- **Google Drive native docs** (Docs/Sheets/Slides) won't open via QuickOffice: they have no
  downloadable bytes and the download seam doesn't pass an `exportMime`. Real Office files stored
  in Drive open fine. (The stand-alone `gdrive-files` app *does* export native docs.)
- **Dropbox is interactively verified on device**: list, open, and **save-back** work, and the
  listing-reliability + auto-refresh fixes above were driven by that testing. Box / OneDrive /
  Drive share the identical reroute code but their interactive test is still blocked on provider
  keys (no account can be added yet).
