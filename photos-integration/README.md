# Photos-app integration

Makes a Dropbox folder appear as an **album inside the stock Photos app**
(`com.palm.app.photos`), the way Facebook/Photobucket "Synergy" albums used to. Verified
end-to-end: a Dropbox `/Camera Uploads` image syncs down through the modern curl and renders
as a native album.

## Why this is mostly a backend job

The Photos app is **100% MojoDB-driven** — it never loads a remote URL. A backend
aggregator (`com.palm.service.photos`) discovers cloud accounts, calls a per-provider
`listAlbums`/`listPhotos`, **downloads the bytes to local storage**, writes
`com.palm.media.image.album:1` / `.file:1`, and the app just renders local file paths. So
the webview's dead TLS is irrelevant to *display* — the entire problem is getting bytes to
disk, which is one function in the aggregator.

```
account (PHOTO.UPLOAD capability)
   → aggregator com.palm.service.photos  (discovers the account)
   → com.palm.service.dropbox/listAlbums + /listPhotos   (provider methods, in the Dropbox service)
   → Dropbox get_temporary_link  (pre-signed https URL)
   → curl download to /media/internal/.photosApp/<templateId>/<user>/<album>/   ← the TLS patch
   → com.palm.media.image.file:1 + thumbnails
   → Photos app renders the local files
```

## The 4-point recipe (works for any cloud photo source)

1. **Account template** — add a `PHOTO.UPLOAD` capabilityProvider whose `implementation` /
   `onEnabled` / `onDelete` / `onCredentialsChanged` point at `com.palm.service.photos` (the
   aggregator, **not** your service). Add `com.palm.service.photos` to the template's
   `read`+`writePermissions`. See `dropbox/account/com.palm.dropbox/com.palm.dropbox.json`
   (and every locale override — locale files win over the base).

2. **Aggregator routing** — `Utils.js.patch` adds a `case "com.palm.dropbox"` to the
   **hardcoded** `templateId → serviceName` switch (the provider name is *not* derived from
   the template). We point it at `com.palm.service.dropbox` so the provider methods live in
   the already-bus-registered Dropbox service (no new LS2 role / bus rescan needed).

3. **Provider methods** — `listAlbums` / `listPhotos` in the Dropbox service
   (`dropbox/service/com.palm.service.dropbox/commands/`). One Dropbox folder = one album
   (`photolib.js` `ALBUM_PATH`, default `/Camera Uploads`) to bound how much auto-downloads.
   Shapes the aggregator expects:
   - `listAlbums` → `{returnValue, albums:[{aid, name, size:{images:N}}]}`
   - `listPhotos` → `{returnValue, photos:[{pid, src_big, src_small, caption, type:"image", fileName}]}`

     `src_big` is a Dropbox `/2/files/get_temporary_link` (pre-signed, no-auth https, ~4h),
     so the downloader needs no token. `fileName` carries the real name+ext (temp-link URLs
     have none).

4. **The TLS patch** — `Sync-Manager.js.patch`. Stock `_downloadAndUpdateDb` fetched images
   with `node_http.createClient(80, domain)` — plain HTTP, port 80, no TLS. Replaced with a
   `child_process.spawn` of the bundled curl (`/var/dropbox-tls/curl`, full https temp link,
   `--create-dirs`, `LD_LIBRARY_PATH=/var/dropbox-tls`, `--cacert` the system store). A
   sibling patch to `_doPhotoWork` honors `photo.fileName`. Everything downstream (DB,
   extractfs thumbnails, local rendering) is unchanged and TLS-free.

## Applying the patches

The patches are against the stock `com.palm.service.photos/photos-src/base/` tree
(paths are `a/photos-src/base/…`). On device:

```sh
cd /usr/palm/services/com.palm.service.photos/photos-src/base
cp Utils.js Utils.js.orig; cp Sync-Manager.js Sync-Manager.js.orig   # keep a backup
patch -p1 -d /usr/palm/services/com.palm.service.photos < Utils.js.patch
patch -p1 -d /usr/palm/services/com.palm.service.photos < Sync-Manager.js.patch
# restart the photos service (kill its pid) so it reloads
```

Round-trip verified: applying each patch to the pristine stock file reproduces the
deployed version exactly.

## Enabling it on an account

Adding `PHOTO.UPLOAD` to the template does **not** retro-fit an account created earlier —
the capability is written to the account record at enable time. User path: **Settings →
Accounts → Dropbox → enable the "Photos" toggle** (fires `modifyAccount` → `onEnabled` →
sync). Force a sync from a shell with
`luna-send -n 1 -f palm://com.palm.service.photos/remoteSyncAlbums '{"accountId":"…"}'`.

> Note: a synced photo is downloaded once (deduped by Dropbox file id); disabling the
> capability does not purge the media DB records, so only a *new* file id re-downloads.
> And every image in the album is copied to local storage — hence the single-folder scope.
