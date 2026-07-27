# Chatthreader WhatsApp group-name JID guard

WhatsApp group chats intermittently reverted to their raw JID
(`<digits>-<digits>@g.us`) instead of the group subject in the conversation list.

## Root cause
The imtransport derives a group message's `channelDisplayName` from the group's
libpurple blist alias (`purple_chat_get_name`), which is set **asynchronously** on
connect (combined-plugin commit `a63ddc5`). During post-connect **backfill**, group
messages processed *before* the alias is set fall back to the raw match key (the JID).
The chatthreader names the thread from the **latest** message's `channelDisplayName`,
so a stray JID-stamped backfill message downgraded the thread name on every reconnect.

## Two-layer fix
1. **imtransport** (`LibpurpleAdapter.cpp`, committed in this repo): if the resolved
   `channelDisplayName == channelName` (no human room title resolved), leave it NULL so
   the chatthreader keeps the thread's existing good name. Rebuild + reboot to deploy.
2. **chatthreader** (this dir — stock on-device Palm service, not vendored): reject a
   raw-JID value everywhere the channel/thread name is set —
   - `imchannel.js`: `_isRawId()` helper; update branch ignores a JID `channelDisplayName`;
     create branch never stores the JID as `displayName` (leaves it unset until a named
     message arrives).
   - `dbmodels.js`: the channel-thread self-heal never copies a raw-JID channel name onto
     the thread.

`_isRawId` matches `/^\d+(-\d+)?@g\.us$/` or a name equal to the match key.

## Install
`sh install.sh` over novacom (remounts / rw, backs up to `*.b4jidguard`). The chatthreader
is forked per-activity, so the new JS loads on the next message — no restart needed.
