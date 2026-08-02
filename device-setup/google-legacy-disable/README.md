# Remove the defunct stock "Google" account

The stock 2011-era `com.palm.google` Synergy account offers five capabilities, all now dead:

- **MESSAGING/IM** (`com.palm.google.talk`, `type_gtalk` -> `prpl-jabber`) — Google Talk's XMPP
  chat servers shut down years ago.
- **CONTACTS**/**CALENDAR** (`com.palm.service.contacts.google`/`com.palm.service.calendar.google`)
  — both use Google's old ClientLogin-era sync APIs, deprecated/shut down long ago in favor of
  OAuth2 + modern REST APIs the stock 2011 image never speaks.
- **MAIL** (`com.palm.google.mail`) — rides the *shared* `com.palm.imap` service (generic
  IMAP/SMTP) with `imap.gmail.com`/`smtp.gmail.com` pre-filled. Google removed "less secure app
  access" (plain username+password IMAP) in 2022 — this can no longer authenticate either.
- **DOCUMENTS** (`com.palm.google.documents`) — a bare capability declaration with **no
  implementation at all**, already inert. This repo's own `cloud/gdrive` (`com.palm.gdrive`,
  modern OAuth2+PKCE) is the actual, working replacement — a completely separate account
  template, no relation.

`remove-google-legacy.sh` strips it out, same non-destructive pattern as `../skype-disable` and
`../legacy-im-disable`.

## What it removes (moves to `/media/cryptofs/google-legacy-disabled-backup`, reversible)

- **Contacts sync** — the `com.palm.service.contacts.google` service dir, its LS2 roles + D-Bus
  service, and its db8 kinds/permissions (`com.palm.contact.google`,
  `com.palm.contact.transport.google`, `com.palm.account.contacts.google`).
- **Calendar sync** — the `com.palm.service.calendar.google` service dir, its LS2 roles + D-Bus
  service, and its db8 kinds/permissions (`com.palm.calendar.google`,
  `com.palm.calendarevent.google`, `com.palm.calendar.transport.google`,
  `com.palm.calendarevent.transport.google`, `com.palm.account.calendar.google`).
- **The account template itself** — `com.palm.google`.
- **The now-orphaned Jabber/XMPP libpurple plugin** — `libjabber.so`/`libjabber.so.0`/
  `libjabber.so.0.0.0`/`libxmpp.so` (`prpl-jabber`). `../legacy-im-disable` deliberately kept these
  because `com.palm.google`'s IM capability was their last remaining consumer — with that account
  template gone (this script), they're genuinely orphaned, same "dead by construction" reasoning
  (libpurple's `plugin.c` version-gates them anyway) as the AIM/ICQ/oscar cleanup.

Nothing is deleted; it is moved under `/media/cryptofs/google-legacy-disabled-backup`. `rm -rf` that once
you're sure.

**Deliberately NOT touched:**
- **`com.palm.imap`** (service + LS2 role + D-Bus service + `com.palm.imap.email:1` kind) — Google's
  MAIL capability only *reuses* this generic IMAP/SMTP engine with Gmail's hostnames pre-filled; it
  has no Google-specific service of its own. The standalone "IMAP" account type this backs is still
  genuinely useful (any real IMAP/SMTP provider), so it stays.
- **`com.palm.immessage.libpurple:1`/`com.palm.imcommand.libpurple:1`** — shared with every
  connector this repo ships; Google Talk's `capabilityProvider` entry just disappears along with
  the whole account template, no dedicated kind ever existed for it.
- Trusted root CA certs, shared framework icon assets, `ipkg` bookkeeping — same reasoning as
  `../legacy-im-disable`.

## Apply on a device

    mount -o remount,rw /
    sh /media/internal/remove-google-legacy.sh     # after pushing it there
    sync    # then reboot

Reboot so the accounts service drops the cached template. Already-registered db8 kinds stay in
the store but are inert; an image built with this patch applied never registers them.
