# Photos integration

Gives the stock **Photos & Videos** app (`com.palm.app.photos`) a per-service icon for each
cloud photo library, so revived Box / Dropbox accounts are visually distinguishable in the
**Libraries** list instead of all showing the same generic thumbnail under the account holder's
name.

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

Append the two missing service classes (plus their 20x20 variants), pointing at bundled 40x40 /
20x20 badges:

| Template | `type` | CSS class | Icon |
|---|---|---|---|
| `com.palm.boxnet` | `boxnet` | `.library-navigation-icon-boxnet` | `icon_boxnet_40x40.png` (blue badge, white box) |
| `com.palm.dropbox` | `dropbox` | `.library-navigation-icon-dropbox` | `icon_dropbox_40x40.png` (white badge, flat glyph) |

No JS change is needed - the class is already applied per account; only the CSS rule + image were
missing. Box gets a mostly-blue badge and Dropbox a mostly-white one, so the two "same holder name"
libraries are easy to tell apart at a glance.

## Applying

```sh
D=/media/cryptofs/apps/usr/palm/applications/com.palm.app.photos
patch -p1 -d "$D" < patches/LibraryNavigationPanel.css.patch
cp assets/icon_boxnet_40x40.png  assets/icon_boxnet_20x20.png  "$D/images/"
cp assets/icon_dropbox_40x40.png assets/icon_dropbox_20x20.png "$D/images/"
# relaunch the Photos card (cold launch reloads its CSS)
```

The badges are derived from the official brand art (Box's box-social wordmark; the current flat
Dropbox glyph) - the same sources used for the account-template icons under `box/` and `dropbox/`.
