# QuickOffice integration

Repairs QuickOffice's broken remote-file support by rerouting it onto our modern cloud
services — **Dropbox, Box, OneDrive, Google Drive, pCloud, Yandex Disk, and kDrive**. Those
accounts' documents list, open, edit, and **save back** in QuickOffice's native viewer again — no
native reversing required. (Flickr is photos-only, so it isn't a QuickOffice provider.)

**Adding a provider needs zero changes to these files.** Routing is **account-derived**: any
account whose `DOCUMENTS` capability is implemented by a `palm://com.palm.service.*` LS2 service
(the shared `_cloudcore` `listFolder`/`downloadFile`/`uploadFile` contract) is picked up
automatically. A new connector ships its `_cloudcore` service + account template and is instantly a
QuickOffice provider — no per-provider component, switch case, or mxId. (kDrive was the first
provider added *without touching QuickOffice at all*.)

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

## The reroute (`source/RemoteFileService.js`)

> This file is heavily rewritten (the whole modern-reroute subsystem, ~50% custom), so it's shipped
> as a **full drop-in replacement** in `source/`, not a patch — there's no stock baseline left to
> diff against cleanly.

Three seams in `RemoteFileService.js`. Each is **service-agnostic** *and* **provider-agnostic**: a
`_modernSvc(account)` helper (in all three kinds) resolves the account's revival service URI via
`QOWT.MX.modernServiceUriForAccount(account)`, then **lazily creates and caches one `PalmService`
per URI** (`this._modernSvcCache`); it returns `null` for a legacy MX account. The URI itself comes
from the account (see [Account recognition](#account-recognition-sourcefilestorejs--patchesfilestorejspatch)),
so there is **no per-provider component list and no mxId switch** — every backend that speaks the
shared `listFolder`/`downloadFile`/`uploadFile` contract is served by the one code path.

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

**History:** an earlier revision hard-coded the backends as static `PalmService` components
(`modernDbx`/`modernBox`/…) and mapped them with a `_modernSvc(mxId)` switch — a block that had to
be edited in **three kinds** every time a provider was added (and once shipped a component to only
one kind, so `_modernDownload` threw on `this.$.modernDbx`). The lazy, account-derived
`_modernSvc(account)` replaced all of that: no static components, no switch, so the class of
"forgot to add it to a kind" bug is gone by construction.

## Listing reliability (found in first on-device test)

The first real device run surfaced two list bugs, both now fixed in `RemoteFileService.js.patch`:

- **Every entry appeared twice.** The picker calls `cancelAll()` + `getFiles()` *twice* per
  folder open; the legacy path relied on `cancelAll()` (`CancelRequestFromGroup`) to drop the
  first in-flight request so only one render happened. Our modern `PalmService` list calls
  weren't cancellable, so **both** completed and both rendered. `cancelAll()` now also calls
  `cancel()` on every cached revival `PalmService` (`this._modernSvcCache`; enyo `Service.cancel()`
  destroys its outstanding `Request` children) and bumps a list generation; `_modernListOk` drops
  any response whose stamped generation is stale. One render per open.
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

- **Pull-to-refresh** (`FolderContentsList.js.patch`). *First attempt* hooked the list's published
  `onScroll`/`onScrollStop` and watched for a negative `getScrollTop()` — but a `VirtualList`
  **contains** a `Scroller` (`fileList.$.scroller`) rather than being one, so those events fire to
  the `VirtualList`, not to us, and it never triggered on device. The working version reaches the
  scroller's drag **strategy** (`fileList.$.scroller.$.scroll`) and wraps its
  `startDrag`/`drag`/`dragFinish`. It arms only when the drag **starts at the top** and the **raw
  finger travel** (`e.pageY - strat.my`, immune to the strategy's overscroll damping) exceeds an
  80px threshold, then fires on release. It calls the new `refreshNow()` — drop `fsoCache`, reset
  paging, `scheduleRender(RESET)` — which re-queries through the always-fresh modern `getFiles`.
- **Toolbar Refresh button** (`FolderContentsPane.js.patch`, a fourth patched file). An icon
  `ToolButton` on the **left** of the footer toolbar (opposite the New-document / Share buttons),
  wired to the same `refreshNow()`. The icon (`assets/toolbar-icon-refresh.png`, deployed to each
  app's `images/`) is the browser app's `menu-icon-refresh` sprite — already the 32×64 two-state
  (normal/pressed) format the QuickOffice toolbar icons use, so it drops in unchanged.

<a name="account-recognition-sourcefilestorejs--patchesfilestorejspatch"></a>
## Account recognition (`source/FileStore.js` / `patches/FileStore.js.patch`)

This is where the reroute becomes **provider-agnostic**. Stock QuickOffice mapped accounts by
`loc_name.toLowerCase()` in `FileStore.addUpdateAccountCallback` — a hard-coded switch (`"dropbox" →
mxId "drop"`, `"box.net" → box`, …). The first revival added a `case` per provider there; that was
the duplication (a case here **plus** a component **plus** a switch arm in each of three kinds in
`RemoteFileService.js`).

It's now a single check. `_modernServiceUri(acct)` scans the account's `capabilityProviders` for the
`DOCUMENTS` capability and returns its `implementation` URI **iff** it starts with
`palm://com.palm.service.` (i.e. a `_cloudcore` service). When it matches, `FileStore`:

1. registers `QOWT.MX.modernServiceByAccountId[acct._id] = serviceUri` — the map
   `RemoteFileService._modernSvc(account)` reads to route (every file-op object already carries
   `_id`, so nothing else has to be threaded through); and
2. tags the account generically (`accountType = "modernCloudAccount"`, `mxId = "modern"`, both inert
   — the modern path is keyed on `_id` and bypasses all MX account-type/mxId logic).

Only genuine **legacy** stock providers (Google Docs, stock Dropbox/Box.net, MobileMe — no
`palm://com.palm.service.*` implementation) fall through to the original `loc_name` switch and the
dead MX proxy. So adding a revival provider needs **no edit here**: its template already declares the
`DOCUMENTS` capability with a `palm://com.palm.service.<name>/` implementation, which is all the
detection needs. `capabilityProviders` survives the enyo `Accounts.getAccounts` merge (the framework
itself iterates it in `promoteCapabilityIcons`), so it's reliably present on each cached account.

## Companion service changes

Each service's `listFolder`/`downloadFile`/`uploadFile` lists `com.quickoffice.webos` /
`com.quickoffice.ar` in `allowedAppIds`, and `downloadFile` passes `curl --create-dirs` so
`/media/internal/.qo/` is created if absent. For **save-back**, each service gained an
overwrite-by-id path: Dropbox `mode:"overwrite"`, Box `uploadNewVersion`, OneDrive
`uploadReplace` (PUT item content), Drive `uploadReplace` (PATCH content), pCloud same-name
re-upload, Yandex `overwrite=true` PUT, kDrive `conflict=version` re-upload.

Because routing is account-derived, this is the **only** side that changes when a provider is added:
a new `_cloudcore` service + its account template (declaring the `DOCUMENTS` capability with a
`palm://com.palm.service.<name>/` implementation, and listing the QuickOffice appIds in
`allowedAppIds`). No QuickOffice edit at all.

## Applying

Everything applies to **both** apps (`com.quickoffice.webos` and `com.quickoffice.ar` — their
`RemoteFileService.js`, `FileStore.js`, `FolderContentsList.js` and `FolderContentsPane.js` are
byte-identical, verified against the 2.1.2113 / 10.3.484 IPKs). `RemoteFileService.js` and
`FileStore.js` are **full drop-in files** (`source/`); `FolderContentsList.js` and
`FolderContentsPane.js` are still small **patches**:

```sh
for app in com.quickoffice.webos com.quickoffice.ar; do
  d=/media/cryptofs/apps/usr/palm/applications/$app
  cp source/RemoteFileService.js "$d/source/"        # full drop-in (heavily rewritten)
  cp source/FileStore.js         "$d/source/"        # full drop-in (also patches/FileStore.js.patch)
  patch -p1 -d "$d" < patches/FolderContentsList.js.patch
  patch -p1 -d "$d" < patches/FolderContentsPane.js.patch
  cp assets/toolbar-icon-refresh.png "$d/images/"    # icon for the toolbar Refresh button
done
# restart LunaSysMgr so QuickOffice reloads its (cached) app JS
```

`patches/FileStore.js.patch` is **round-trip verified** against the pristine IPK `FileStore.js`
(applying it reproduces `source/FileStore.js` exactly) and is kept for readers who want to see the
diff. `RemoteFileService.js` is provided only as a full file: it's rewritten too far past the stock
baseline for a patch to stay reliable. The two `FolderContents*` patches round-trip against pristine.

## Limitations / TODO

- **Google Drive native docs** (Docs/Sheets/Slides) won't open via QuickOffice: they have no
  downloadable bytes and the download seam doesn't pass an `exportMime`. Real Office files stored
  in Drive open fine. (The stand-alone `gdrive-files` app *does* export native docs.)
- **Box + Dropbox are interactively verified on device**: list, open, and **save-back** work, and
  the listing-reliability + auto-refresh fixes above were driven by that testing. Google Drive,
  OneDrive, pCloud, Yandex Disk and kDrive share the identical account-derived reroute code; their
  interactive test lands as each account is added (kDrive's account + stored-credential `listFolder`
  are verified service-side).
- **Account-derived routing was validated live**: adding kDrive as the 7th provider required **no
  change to `RemoteFileService.js`/`FileStore.js`** — it was recognised purely from its account's
  `DOCUMENTS` capability implementation URI.

## File-list & Save-As polish (`source/File.js`, `source/SaveAs.js`, `css/FileBrowser.css`)

Later on-device polish, all full drop-ins of stock QuickOffice files:

- **Consistent localized dates** (`source/File.js`): `getTimestampFormatted()` dropped the stock
  recency-relative variants (today / last-7-days / this-year / other-year, which mixed styles in one
  list) for a single `enyo.g11n.DateFmt` (`date:"medium" dateComponents:"dmy" time:"short"`) — every
  row shows the same full date+time, localized to the system format (month names, component order,
  12/24h). This surfaced that the modern connectors fed unparseable timestamps: kDrive sent UNIX
  **seconds** and Box an RFC-3339 **offset** (`…-08:00`) — `File.parseUtcDate` only strips a trailing
  `Z`, so both were dropped (blank date → the row collapsed to one line and mis-aligned the icon).
  Fixed in each adapter by normalizing to ISO-`Z` (`new Date(x).toISOString()`; kDrive `×1000` first).
- **List-row layout** (`css/FileBrowser.css`): the row icon is `float:left` (36px), so on a
  single-line row (a dateless folder, e.g. Dropbox's) it overflowed into the next row. Floor the row
  at `min-height:44px`, and reserve the date line for dateless rows with `.file-time:empty::before {
  content:"\00a0" }` so they render at the same two-line height as dated rows (real content → white,
  VirtualList-safe; a stretched `min-height` left a dark gap, and a per-row JS class is misapplied by
  VirtualList's row recycling — both were tried and rejected).
- **"Choose a location to save" sizing** (`source/SaveAs.js`): the destination list was a fixed
  `200px` `VirtualList`; `_sizeListToContent()` now grows it to fit the providers (measuring the
  rendered row height, clamped to a max, then scrolls) and re-sizes as accounts stream in.
