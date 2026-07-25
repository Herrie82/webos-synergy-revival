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
- **Binaries** — `skypem`, `skypevalidator`, the SkypeKit engine, `/var/skypekit`, `libpalmgstskype.so`.

Nothing is deleted; it is moved under `/var/skype-disabled-backup`. `rm -rf` that once you're sure.

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
