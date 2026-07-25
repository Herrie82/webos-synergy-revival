# account-keepdata — forward `keepData` through the account delete flow

The Accounts "Remove Account" dialog offers **"Keep this account's data on this
device"** (see `enyo-1.0` `remove-account.js`). Ticking it makes the UI call
`deleteAccount({accountId, keepData:true})`. The account service then unlinks the
account but the capability `onDelete` handler is expected to **keep** the account's
on-device data (messages, contacts, media) instead of purging it.

## The problem

The stock account service (`com.palm.service.accounts`, part of the rootfs — not in
any repo of its own) **drops `keepData`**. Its `notify-deleted.js` calls each
capability provider's `onDelete` with only `{accountId}`, so the transport
(`imlibpurple`) can never tell "keep" from "wipe" and always purges.

## The fix

Two one-line forwards in two handlers (kept, patched, here):

| file | change |
|---|---|
| `handlers/delete.js` | `notifyAccountDeleted({accountId})` → `{accountId, keepData: args.keepData}` |
| `handlers/notify-deleted.js` | `onDelete({accountId})` → `{accountId, keepData: args.keepData}` (and log the value) |

End-to-end:

```
deleteAccount(args.keepData)
  → delete.js          notifyAccountDeleted({accountId, keepData})
  → notify-deleted.js  onDelete({accountId, keepData})
  → imlibpurple onDelete   keep (unlink only)  vs  wipe on-device data
```

`keepData` absent/false ⇒ **wipe** (historical default; the delete-all-by-default
behaviour the user chose). The transport side (gating the db8 purges on `keepData`)
lives in `messaging/imlibpurpleservice`.

## Install

```
./install-account-keepdata.sh [deviceid]
```

Deploys both handlers to `/usr/palm/services/com.palm.service.accounts/handlers/` and
restarts the service (it reloads handlers on respawn). Re-run after a reflash, since
the account service is stock and reverts. Verify by removing an account and checking
the log for `Calling onDelete ... keepData=<true|false>`.
