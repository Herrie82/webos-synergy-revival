# chatthreader-person-link-fix — Messaging shows the contact name (not a bare number)

## Symptom
A WhatsApp (or other IM) conversation shows the raw address (`+31684449061`) instead of the
contact's name — even though the contact **is** synced (its buddy/presence entry and its
`com.palm.person` record both have the right name and are linked).

## Root cause (confirmed on-device)
The chatthreader (`com.palm.messaging.chatthreader`, a stock Palm service) names a 1:1 thread by
resolving the message's address to a `com.palm.person` via `ContactsLib Person.findByIM`.

For `type_whatsapp`, `Messaging.Utils.normalizeAddress` **strips the leading `+`**
(`+31684449061` → `31684449061`). But a contact's WhatsApp IM can be stored with the `+` **kept**
in its person-record `normalizedValue` (seen on an aggregate person merged with a CardDAV/Google
contact — its `ims.normalizedValue` is `+31684449061`). The person index then only matches the
`+`-form, so `findByIM` (searching the stripped form) **misses** → `person` is `undefined` → the
thread is created with **no `personId`** and `displayName` == the bare number.

Incoming threads hide this because they inherit `displayName` from the message's `from.name`. An
**outgoing-only** thread (you composed to the number and never received back) has no such fallback,
so it shows the number forever.

The buddy record (`com.palm.imbuddystatus`, in TempDB) is keyed on the **exact raw username**
(`+31684449061`) and already carries the correct `personId` + `displayName` — it's set by
`personChanged.addPersonIdToBuddy`, an exact-match path that does **not** depend on the flaky
normalized IM index. So it's the authoritative bridge.

The SAME `+` mismatch bites in **two** association paths, so both are fixed:

## The fix (three parts)

### 0. `contacts-plugin-messaging-utils.js` — the canonical linker path (fires on contact sync/re-link)
`contacts.plugin.messaging/utils.js` `getUnassociatedChatThreads` links a person's pre-existing
unassociated chatthreads when the person gains an im/phone (contact sync, re-link, or a person merge).
Its IM branch matched the chatthread by the im's `normalizedValue` **verbatim** (`+31684449061`), but
WhatsApp threads are keyed **without** the `+` (`31684449061`) → the lookup missed → the thread was
never linked. Fix: strip a leading `+` for `type_whatsapp` so the key matches. This is the layer that
links a thread that was created **before** its contact synced — no message needed.

### 1. `newmessageassistant.js` — prevents it for ALL new/updated threads (the per-message fix)
`contactReverseLookup`: when `Person.findByIM` returns **empty**, fall back to a new
`findPersonViaBuddy(address, serviceName)` that looks up `imbuddystatus` by exact
`username` + `serviceName`; if it has a `personId`, fetch that person and return it so the thread
gets associated (and the existing "adopt a pre-person thread" logic in `dbmodels.js` stamps the
name). Zero cost for already-resolved contacts (only fires on a `findByIM` miss); the lookup is
indexed (mirrors `personChanged`'s query), so no new index.

Deploy: `sh install.sh` (over novacom). Backs up the stock file to `newmessageassistant.js.b4personlink`.
The chatthreader is forked per-activity, so the new JS loads on the next message — no restart.

### 2. `repair-existing-threads.sh` — one-time cleanup of ALREADY-broken threads
Joins every 1:1 chatthread that has no `personId` to its `imbuddystatus` buddy (exact
`replyAddress == username`) and stamps `personId` + `displayName`. Idempotent; run once after
install. (Not needed going forward — part 1 stops new ones. Pushes `repair-ondevice.sh`, which pages
db8 and does the join in on-device node.)

## Verify
```
# thread should now have a personId + a real displayName
luna-send -i -a com.palm.configurator palm://com.palm.db/find \
  '{"query":{"from":"com.palm.chatthread:1","where":[{"prop":"normalizedAddress","op":"=","val":"31684449061"}]}}'
```

## Undo
`cp newmessageassistant.js.b4personlink newmessageassistant.js` (on-device) — reloads on next message.
