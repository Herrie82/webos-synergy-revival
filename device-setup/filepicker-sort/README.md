# FilePicker: newest-first album sort

Makes the system **FilePicker** (the attach-a-picture dialog used by Messaging, Email, etc.) list an
album's pictures **newest-first** instead of oldest-first. Practically: your most recent **Screen
captures** show at the top of the grid instead of scrolling to the bottom.

## What changed

One line in the stock luna-systemui FilePicker image grid,
`/usr/lib/luna/system/luna-systemui/app/FilePicker/AlbumGridView.js`, in `dbQuery()`:

```js
inQuery.desc = true;   // list newest captures first
```

The `com.palm.media.types` image records have `createdTime = 0`, so we can't order by a real capture
time. Instead we reverse the album's index scan with `desc`: the media indexer inserts a record as
each screenshot is taken, so the newest capture has the newest `_id`, and `desc:true` flips db8's
default oldest-first result order to newest-first. No new index needed (`desc` just reverses the
existing `albumId + appCacheComplete` scan).

`AlbumGridView.js` here is the full patched file (this is a stock luna-systemui file, not a bundled
app, so it lives in webos-synergy-revival rather than core-apps).

## Install (on device)

```sh
# from the host:
novacom -d topaz-linux put file:///tmp/AlbumGridView.js < AlbumGridView.js
novacom -d topaz-linux put file:///tmp/install-filepicker-sort.sh < install-filepicker-sort.sh
novacom -d topaz-linux run file:///bin/sh /tmp/install-filepicker-sort.sh
# then reload the UI:
novacom -d topaz-linux run file:///bin/sh -c 'stop LunaSysMgr; sleep 2; start LunaSysMgr'
```

Keeps `AlbumGridView.js.orig` as a backup; `/` is remounted rw for the copy (the file is on the
read-only rootfs).
