# Remove the defunct AOL/AIM and Yahoo! stacks

AOL Instant Messenger shut down in 2017; Yahoo! Messenger (and Yahoo!'s Contacts/Calendar sync)
shut down in 2018. The stock TouchPad image still ships and wakes both full Synergy stacks —
`com.palm.aol` (AIM, riding the shared `imlibpurple`/`imaccountvalidator` infrastructure) and
`com.palm.yahoo` (its own dedicated closed-source IM transport, plus separate Contacts and
Calendar sync services — none of it libpurple-based). All dead weight. `remove-legacy-im.sh`
strips it out, same non-destructive pattern as `../skype-disable`.

## What it removes (moves to `/media/cryptofs/legacy-im-disabled-backup`, reversible)

- **AOL/AIM** — the `com.palm.aol` account template, and `imaccountvalidator` (binary + LS2 role +
  D-Bus service). `imaccountvalidator` is the generic username/password validator for legacy
  templates; AOL is its only stock consumer — every connector this repo ships uses its own
  `customUI` instead (confirmed by grepping every account template for it).
- **Yahoo! IM** — `imyahootransport`, its LS2 role + D-Bus service, the `com.palm.imyahoo` db8-watch
  activity, and its db8 kinds (`com.palm.imcommand.yahoo`, `com.palm.imloginstate.yahoo`,
  `com.palm.immessage.yahoo`, `com.palm.contact.imyahoo`, `com.palm.imbuddystatus.yahoo` in tempdb).
- **Yahoo! Contacts sync** — the `com.palm.service.contacts.yahoo` service dir, its LS2 roles +
  D-Bus service, and its db8 kinds/permissions (`com.palm.contact.yahoo`,
  `com.palm.contact.transport.yahoo`, `com.palm.account.contacts.yahoo`).
- **Yahoo! Calendar sync** — the `com.palm.service.calendar.yahoo` service dir, its LS2 roles +
  D-Bus service, and its db8 kinds/permissions (`com.palm.calendar.yahoo`,
  `com.palm.calendarevent.yahoo`, `com.palm.calendar.transport.yahoo`,
  `com.palm.calendarevent.transport.yahoo`, `com.palm.account.calendar.yahoo`).
- **Yahoo! master/auth service** — `yahoo-service`, its LS2 role + D-Bus service, the
  `com.palm.yahoo.authservice` db8 kind, and the `com.palm.yahoo` account template itself.
- **Orphaned oscar/AIM/ICQ libpurple plugins + redundant SSL backends** —
  `/usr/lib/purple-2/{libaim.so,libicq.so,liboscar.so,liboscar.so.0,liboscar.so.0.0.0,ssl-gnutls.so,ssl-nss.so}`.
  Confirmed dead two ways: with `com.palm.aol` gone, nothing anywhere references `type_aim`/
  `type_icq` or `prpl-aim`/`prpl-icq` any more; and libpurple's own `plugin.c` rejects any plugin
  whose baked-in `major_version` doesn't match the engine's `PURPLE_MAJOR_VERSION` (2) — these were
  built against webOS's ancient pre-2.0 libpurple, so they'd be silently skipped at every plugin
  scan even if left in place. `ssl-gnutls.so`/`ssl-nss.so` are likewise orphaned: nothing in this
  repo uses anything but `ssl-openssl.so` (confirmed by grep).

Nothing is deleted; it is moved under `/media/cryptofs/legacy-im-disabled-backup`. `rm -rf` that once you're sure.

**Deliberately NOT touched** (out of scope, low value, some risk):
- AOL/Yahoo trusted root CA certs under `/etc/ssl/certs/trustedcerts/` — harmless unused trust
  anchors.
- Shared framework icon assets under `/usr/palm/frameworks/mojo*` (`aol-*.png`/`yahoo-*.png`) —
  generic image bundles that could plausibly be referenced by something else via shared path
  convention; not worth the risk for a few KB of unused icons.
- `ipkg`'s own package bookkeeping under `/usr/lib/ipkg/info/` — package-manager metadata, not
  consulted at runtime.
- The one-time `012-yahooimtransport-imcontact-fixup.js` migration script — already ran years ago,
  inert.
- `/usr/palm/data/com.palm.service.contacts.yahoo` — possible user data; same "never touch data"
  principle `skype-disable` follows.

## `libjabber.so`/`libxmpp.so` — moved to `../google-legacy-disable`

Unlike AIM/ICQ, the Jabber/XMPP plugin (`prpl-jabber`) had one more live consumer when this script
was first written: `com.palm.google`'s `MESSAGING` capability (`com.palm.google.talk`) maps
`type_gtalk` -> `prpl-jabber` (see `imlibpurpleservice`'s `LibpurpleAdapter.cpp`). That whole
account template (Mail/Contacts/Calendar/Documents, not just Talk) turned out to be equally dead —
see `../google-legacy-disable`, which removes the account template *and* these plugin files
together, now that nothing references `prpl-jabber` any more.

## Apply on a device

    mount -o remount,rw /
    sh /media/internal/remove-legacy-im.sh     # after pushing it there
    sync    # then reboot

Reboot so the accounts service drops the cached templates and the activity manager deregisters the
now file-less `imyahoo` activity. Already-registered db8 kinds stay in the store but are inert; an
image built with this patch applied never registers them.
