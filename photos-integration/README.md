# Photos integration

Two things: (1) `patches/Utils.js.patch` routes each revived cloud account's photo capability to
its service (the `templateId → serviceName` routing the aggregator uses to call
`listAlbums`/`listPhotos`) — this is what makes **Dropbox, Box, OneDrive, pCloud, Flickr, kDrive,
and Yandex Disk** appear as photo sources at all; and (2) `patches/LibraryNavigationPanel.css.patch` gives
the stock **Photos & Videos** app (`com.palm.app.photos`) a per-service **icon** for each library,
so they're visually distinguishable in the **Libraries** list instead of all showing the same
generic thumbnail under the account holder's name.

> **Routing is data-driven, not copy-pasted.** Every synergy-revival provider has the same photo
> capability shape and a `serviceName` that's just `templateId` with `com.palm.` → `com.palm.service.`,
> so `Utils.js.patch` lists them as **one fall-through `case`** (Dropbox/Box/OneDrive/pCloud/Flickr/
> kDrive/Yandex Disk) that derives `serviceName` — adding a provider is a **one-line `case`**. Only
> the stock 2011 providers (facebook/photobucket/snapfish), which genuinely differ, stay explicit.
>
> **Photo-URL styles differ by provider, handled in each provider's own `listPhotos`:** kDrive/Box
> carry `?access_token=` in the URL; OneDrive/pCloud/Flickr return ordinary pre-signed/static URLs;
> **Yandex Disk** (like Dropbox) has no static URL, so it resolves a short-lived signed
> `/resources/download` href **per photo**. All are self-authenticating, so the generic
> `Sync-Manager` curl fetch needs no change. Yandex is bundled with its Library icon
> (`icon_yandexdisk_{40x40,20x20}.png`) and surfaces its camera-uploads folder (`system_folders.photostream`)
> as the album, falling back to `Pictures`.

## What was broken

The Libraries list renders each cloud source's icon from a CSS class, not from the account's
`iconSmall`/`iconLarge` fields (those are set to a literal `"FIXMEFIXMEFIXME_20x20.png"` in
`PhotoAccounts.js` - dead stock code). In `LibraryNavigationPanel.js`:

```js
// type = last dotted segment of the templateId: "com.palm.boxnet" -> "boxnet"
var type = a.accountType.split('.'); type = type[type.length-1];
...
item.$.icon.addClass('library-navigation-icon-' + type);   // e.g. -boxnet / -dropbox
```

Stock `LibraryNavigationPanel.css` only defines `library-navigation-icon-{facebook,snapfish,photobucket}`
(the photo services that shipped in 2011). There is **no `-boxnet` or `-dropbox` rule**, so both
revived libraries fall through to the default and render the generic icon.

## The fix (`patches/LibraryNavigationPanel.css.patch`)

Append the missing service classes (plus their 20x20 variants). Rather than bundle a second set of
badges into the Photos app, each rule points **straight at the account-template artwork already on
disk** under `/usr/palm/public/accounts/<template>/images/` - a single source of truth, so an icon
only ever needs updating in one place. `-webkit-background-size: contain` fits the 48px account tile
into the 40px (and 20px) library-icon slots.

| Template | `type` | CSS class | Reused account icon |
|---|---|---|---|
| `com.palm.boxnet` | `boxnet` | `.library-navigation-icon-boxnet` | `com.palm.boxnet/images/box_net_48.png` |
| `com.palm.dropbox` | `dropbox` | `.library-navigation-icon-dropbox` | `com.palm.dropbox/images/dropbox-48x48.png` |
| `com.palm.kdrive` | `kdrive` | `.library-navigation-icon-kdrive` | `com.palm.kdrive/images/kdrive-48x48.png` |
| `com.palm.yandexdisk` | `yandexdisk` | `.library-navigation-icon-yandexdisk` | `com.palm.yandexdisk/images/yandexdisk-48x48.png` |
| `com.palm.onedrive` | `onedrive` | `.library-navigation-icon-onedrive` | `com.palm.onedrive/images/onedrive-48x48.png` |
| `com.palm.mega` | `mega` | `.library-navigation-icon-mega` | `com.palm.mega/images/mega-48x48.png` |
| `com.palm.koofr` | `koofr` | `.library-navigation-icon-koofr` | `com.palm.koofr/images/koofr-48x48.png` |
| `com.palm.hidrive` | `hidrive` | `.library-navigation-icon-hidrive` | `com.palm.hidrive/images/hidrive-48x48.png` |

No JS change is needed - the class is already applied per account; only the CSS rule was missing.

## Applying

```sh
D=/media/cryptofs/apps/usr/palm/applications/com.palm.app.photos
patch -p1 -d "$D" < patches/LibraryNavigationPanel.css.patch
# no image copies needed - the rules reference the account-template icons in place
# relaunch the Photos card (cold launch reloads its CSS)
```
