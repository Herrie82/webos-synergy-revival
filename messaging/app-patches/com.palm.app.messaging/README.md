# com.palm.app.messaging — Synergy cosmetic patches

Two small fixes to the stock **Messaging** app that improve how synergy IM services
(WhatsApp, Discord, Telegram, Signal, Teams, …) are presented. Both are captured as
unified diffs against the **pristine** webOS 3.0.5 app (extracted from
`com.palm.app.messaging_3.0.6606_all.ipk`), plus one new source file.

Device path: `/media/cryptofs/apps/usr/palm/applications/com.palm.app.messaging/`

## 1. IM service label in the contact preview — `app/patches.js` (new) + `patches/depends.js.patch`

Tapping the name in the top bar opens the contacts.ui **DetailsInDialog** preview. It renders
each IM row's label from `imAddress.x_displayType`, whose getter calls the static
`Contacts.IMAddress.getDisplayType(type)`. The contacts framework's `IMAddress` only knows the
legacy services (AIM, Skype, GTalk, ICQ, …); every synergy type — `type_whatsapp`,
`type_discord`, `type_telegram`, … — falls through to the generic **"IM"** default label, so the
preview showed "IM" where the Contacts app shows the real service.

`app/patches.js` wraps that one static so synergy types return their real service name
("WhatsApp", "Discord", …) while legacy services are untouched. `Contacts.IMAddress` and
`ContactsLib.IMAddress` are the same module export, so patching it once covers every widget
(DetailWidget and DetailsInDialog alike).

`depends.js.patch` loads `app/patches.js` — importantly **after** `$enyo-lib/contactsui/`, so
`Contacts.IMAddress` already exists when it runs (the Contacts app's own `patches.js` loads
*before* the library and has to defer; here we don't need to).

Labels use the plain service name to match the framework's existing style (Skype/AIM render
without an "IM –" prefix) and the Contacts app.

## 2. Unread-count pill — `patches/app.css.patch`

The `.unread-count` badge was a fixed 24 px circle backed by `list-unread.png`, which clipped
2–3-digit counts. This grows it into a pill (`width:auto` + `min-width:24px`,
`box-sizing:border-box`) that stays circular for single digits. The stock `list-unread.png` was a
**translucent black** circle (~26% alpha, so it reads as a light grey over the light thread
list), so the fill is `rgba(0,0,0,0.26)` to match it faithfully — a solid `#8f8f8f` read
noticeably darker than the original. Also pins the Prelude face so the number doesn't fall back to
a different font.

> Note: the servers-tab `.server-unread`/`.channel-unread` pills are part of the separate
> servers-tab work and are **not** included in this patch (this patch only touches
> `.unread-count`). They now use the same `rgba(0,0,0,0.26)` fill so every unread badge — threads,
> servers, channels — is one consistent colour; that change belongs in the servers-tab commit.

## Applying

```sh
cd .../com.palm.app.messaging
patch -p1 < patches/depends.js.patch
patch -p1 < patches/app.css.patch
cp .../app/patches.js app/patches.js
```

Then relaunch Messaging (close the card) so `depends.js` is re-read.
