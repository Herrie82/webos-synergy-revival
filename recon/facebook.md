# Facebook (com.facebook.katana 570.x) — RE recon

**webOS connector needed:** CONTACTS, CALENDAR, PHOTO.UPLOAD.

## What the APK shows
- Transport is **100% private GraphQL** (~6,000 refs), no public REST.
- Permission/field strings exist (`user_friends`, `user_events`, `user_photos`, `/friends`,
  `/events`, `/photos`) — but these are the app's *internal* GraphQL field names.

## Why RE does not help
The blocker is **platform policy, not the client**:
- `user_events` permission was **removed from the Graph API in 2018** — no app can be granted it.
- `user_friends` returns only friends *who also use your app* — never the contact list. Contact
  sync (the connector's purpose) has been impossible since the 2015 Graph v2.0 cutover.
- `user_photos` / photo publish require Facebook **App Review** + business verification and are
  denied to hobby apps.
- Katana authenticates with signed `doc_id` GraphQL queries + first-party gatekeepers tied to
  Facebook's own app signature/attestation. Not replicable by a third party.

## Verdict
**Not revivable.** No public or privately-reversed path restores the removed data permissions.
Recommend: delete the connector (CONTACTS/CALENDAR/PHOTO all dead).
