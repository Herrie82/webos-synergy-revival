# Remove the defunct Skype stack

Skype's backend shut down years ago, but the stock TouchPad image still ships and wakes a full Skype
mediator (`skypem`) + SkypeKit engine on demand, plus Skype db8 kinds, an account template and the
`com.palm.app.skype` app. All dead weight. `remove-skype.sh` strips it out.

## What it removes (moves to `/var/skype-disabled-backup`, reversible)

- **Launch path** — `com.palm.skype`/`com.palm.skypevalidator` D-Bus services, the `com.palm.skype*`
  db8-watch activities, the `skypekit`/`skypekit-offport` upstart jobs, the LS2 role files.
- **db8** — the `com.palm.skype/` kind + permission dirs (the `com.palm.*.skypem:1` kinds) under both
  `db` and `tempdb`.
- **Account + app** — the `com.palm.skype` account template and `com.palm.app.skype`.
- **Binaries** — `skypem`, `skypevalidator`, the SkypeKit engine, `/var/skypekit`.

Nothing is deleted; it is moved under `/var/skype-disabled-backup`. `rm -rf` that once you're sure.

**NOT removed despite the name: `/usr/lib/gstreamer-0.10/libpalmgstskype.so`.** Teams, Telegram
(tdlib-purple) and the combined WhatsApp/Facebook plugin all hard-`NEEDED` it (confirmed via
`readelf -d`, each also carries an RPATH of exactly that directory) — they reuse its H.264/media
glue for their own calling, unrelated to Skype. Removing it fails those plugins' entire `dlopen`
(not just a calling feature), silently breaking messaging for those three connectors. This was
moved by an earlier version of this script and had to be manually restored on-device — confirmed
the hard way, don't repeat it.

## Apply on a device

    mount -o remount,rw /
    sh /media/internal/remove-skype.sh     # after pushing it there
    sync    # then reboot

Reboot so the accounts service drops the cached Skype template and the activity manager deregisters the
now file-less Skype activities. Already-registered db8 kinds stay in the store but are inert; an image
built with this patch applied never registers them.

## Related

The Phone app's own Skype references (CallSynergizer SKYPE transport, ContactLookup, SkypebuddyCache,
VideoAddressing, …) are a separate, larger app-side cleanup in `core-apps/com.palm.app.phone`; this
package only removes the system-level Skype stack. See `hasVoipAcct` (commit df4e77e) for the launch
fix that stopped the Phone app opening to "Your Phone Accounts".
