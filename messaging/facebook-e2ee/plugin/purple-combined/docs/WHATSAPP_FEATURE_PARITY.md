# WhatsApp feature parity — status & implementation complexity

Gap analysis of this codebase's WhatsApp support against a "full-featured WhatsApp client"
feature list, plus an effort estimate for closing each gap. Covers two layers:

- **Backend**: `messaging/facebook-e2ee/plugin/purple-combined` (the combined libpurple plugin;
  WhatsApp support is `whatsmeow`-based Go glued into libpurple via cgo — there is no separate
  "whatsapp-only" plugin, see `keep-upstream-unchanged` / architecture notes).
- **UI**: `com.palm.app.messaging` (core-apps repo).

Backend complexity estimates are grounded in the **actual vendored whatsmeow version**
(`go.mau.fi/whatsmeow v0.0.0-20260716095330-85d99080dee8`, per `go.mod`) — function names below
were confirmed to exist in that checkout, not assumed from general WhatsApp/whatsmeow knowledge.
**Re-verify against `go.mod` before scoping work** if the dependency has been bumped since.

Effort scale: **S** = ~1-3 days, **M** = ~1 week, **L** = ~2-4 weeks, **XL** = multi-week, touches
new subsystems or UI paradigms not yet present in the app.

---

## Summary table

| Feature | Status | Backend effort to close | UI effort to close | Overall |
|---|---|---|---|---|
| Authentication (QR, pair code, persistent sessions) | ✅ Done | — | — | — |
| Messaging (E2E, edit, reactions, quote, receipts) | ✅ Done | — | — | — |
| Media (image/video/doc/voice) | ✅ Done | — | — | — |
| Media: GIF as animated media | ❌ Gap | S | S | **S-M** |
| Voice calls | ✅ Done (+video, beyond scope) | — | — | — |
| Groups: create/admin/invite | ❌ Gap | S (calls exist) | M-L (new screens) | **M-L** |
| Communities (subgroup linking) | ❌ Gap | S (calls exist) | L-XL (new nav concept) | **L-XL** |
| Newsletters: create | ⚠️ Follow-only | S | S-M | **S-M** |
| Status posts | ❌ Gap | M (audience logic) | L-XL (new UI paradigm) | **L-XL** |
| Contacts: phone lookup | ❌ Gap | S | S | **S** |
| Contacts: business profile | ❌ Gap | S | S | **S** |
| Presence: outgoing typing | ❌ Gap | S | S | **S** |
| Presence: block/unblock action | ⚠️ Read-only | S | S | **S-M** |
| Chat actions: archive/pin/mute/star | ❌ Gap | S (builders exist) | M-L (4 affordances + 2 views) | **M-L** |
| Profile: push name / status text / own photo | ❌ Gap | S | S-M | **S-M** |
| Privacy settings (last-seen, photo, receipts, etc.) | ❌ Gap | S | S-M | **S-M** |
| Disappearing messages (usable) | ⚠️ Backend-only, no UI | S (calls exist) | M (needs local expiry/purge job) | **M** |
| Modular / native plugins / runtime-agnostic | N/A | — | — | N/A — describes a different library's build-time architecture, not applicable to this single combined `.so` |

---

## Detail

### GIF send/receive — S-M
`send_file.go`'s mimetype switch has no `image/gif` case, so GIFs fall through to
`send_file_document` (sent as a generic file, not an animated message). WhatsApp represents GIFs
as an MP4 **`VideoMessage`** with the `GifPlayback` flag set — confirmed present in the vendored
proto (`proto/waE2E`: `VideoMessage.GifPlayback`, `GifAttribution`). The existing
`send_file_video`/`check_mp4` pipeline already produces a valid `VideoMessage`; the only new work
is (1) detecting `image/gif`, (2) transcoding GIF→MP4, and (3) setting `GifPlayback: true`.
`ffmpeg` is already cross-compiled and deployed on-device (used by the Teams voice-note transcode
path, `teams_contacts.c`), so the transcode step reuses an already-proven toolchain rather than
requiring new cross-build work. Receive side likely already "works" (plays as a normal video) —
looping/muted-autoplay is a UX nicety, not a functional blocker.

### Groups: create / admin / invite / membership approval — M-L
All of the following already exist as direct, exported whatsmeow calls: `CreateGroup`,
`LeaveGroup`, `UpdateGroupParticipants`, `GetGroupRequestParticipants` +
`UpdateGroupRequestParticipants` (membership approval), `SetGroupJoinApprovalMode`,
`SetGroupMemberAddMode`, `SetGroupDescription`, `SetGroupName`, `SetGroupTopic`, `SetGroupPhoto`,
`SetGroupLocked`, `SetGroupAnnounce`, `GetGroupInviteLink`, `JoinGroupWithInvite`/
`JoinGroupWithLink`. The protocol-level heavy lifting is already done by the library — this is
"thin wrapper + cgo glue" work following the exact pattern already used in `groups.go` for
`GetGroupInfo`/`GetJoinedGroups`. The real cost is UI: a "Create Group" flow (name + member
picker — no such picker currently exists in Messaging), an admin panel (rename/photo/description/
lock/approval-mode/add-mode toggles), and a "pending join requests" queue screen. None of these
UI pieces exist today; they'd be new Enyo views, though following well-trodden patterns (similar
in shape to the existing swipe/menu actions in `ConversationList.js`).

### Communities (subgroup linking) — L-XL
Notably, **`ReqCreateGroup` already has an `IsParent` (`types.GroupParent`) field** — creating a
community is the *same* `CreateGroup` call with one field set; `LinkGroup`/`UnlinkGroup`,
`GetSubGroups`, and `GetLinkedGroupsParticipants` are all already exported too. So unlike groups,
protocol complexity here is genuinely low. The cost is entirely architectural on the UI/data side:
the webOS Messaging app's data model and `ConversationList` are built around a **flat list of
1:1/group chat threads** — there's no existing concept of "a chat that is itself a collection of
other chats." Introducing communities means either extending the chatthreader's linking logic
(precedent: the existing group-name/JID chatthreader work) or bolting on a new navigational layer.
This is the one item on this list where the limiting factor is the app's data model, not the
wire protocol.

### Newsletter creation — S-M
`CreateNewsletter(ctx, CreateNewsletterParams{Name, Description, Picture})` already exists and
returns full metadata; `FollowNewsletter`/`UnfollowNewsletter` are already exported (following
channels is already implemented per existing newsletter/channel-icon work — see
`handle_newsletter.go`). `ChannelList.js` currently only browses/joins **existing** channels — no
create flow. Effort is small because the group-create UI work (member/name/photo form) directly
informs this one; a channel-create form is simpler still (no member picker).

### Status posts — L-XL (largest single gap)
Backend: sending a status is explicitly documented in whatsmeow itself — `SetStatusMessage`'s
doc-comment states *"Use SendMessage to types.StatusBroadcastJID"* for status broadcasts, meaning
the existing `send_message.go`/`send_file.go` plumbing is directly reusable for the send path.
`GetStatusPrivacy` is exported (read current audience rules), but the **recipient-list resolution
helper (`getStatusBroadcastRecipients`) is unexported** — we'd have to reimplement "who should see
my status" ourselves from the contact list + `GetStatusPrivacy` rather than call a ready-made
helper. No direct `SetStatusPrivacy`-equivalent was found in this vendored version either — worth
a closer look before committing to a scope.
UI: this is the real cost. WhatsApp's Status is a fundamentally different interaction model —
full-screen story viewer, progress-bar segments, camera capture flow, 24h auto-expiry, "who
viewed" tracking — none of which exists anywhere in the current Messaging app. This is closer to
building a small standalone feature/app than extending an existing screen.

### Contacts: phone lookup & business profiles — S (each)
`IsOnWhatsApp(ctx, phones []string)` and `GetBusinessProfile(ctx, jid)` are both already exported,
single, direct calls — no protocol work at all. Phone lookup wires into the "start new
chat"/contact-add flow (validate before creating a thread — small, contained change). Business
profile data slots into the existing **adaptive Contact Detail popup**
(`contact-detail-dialog-adaptive` — already designed to size-to-content for new field groups),
so it's mostly "add a field group," not new UI infrastructure. Cleanest, lowest-risk items on the
whole list.

### Presence: outgoing typing indicator — S
`SendChatPresence(ctx, jid, state types.ChatPresence, media)` already exists; we currently only
*consume* the incoming event (`handle_chat_presence` in `presence.go`) and never call the
outgoing equivalent. Needs: a debounce in the compose bar (composing-on-keystroke,
paused-after-idle-or-on-send) and a signal path from the compose UI down to the plugin. Contained,
well-understood addition — no new protocol concepts.

### Presence: real block/unblock — S-M
`UpdateBlocklist(ctx, jid, action events.BlocklistChangeAction)` already exists; today we only
call `GetBlocklist` (read-only, used to locally filter incoming messages/contacts —
`handler.go`/`bridge.go`). Needs a "Block/Unblock" action somewhere in the contact/conversation
overflow menu, plus reflecting blocked state in the UI (badge, disabled compose). Backend is a
single call; the work is the UI affordance and state reflection.

### Chat actions: archive / pin / mute / star — M-L
This was expected to be the hardest backend item (WhatsApp's archive/pin/mute/star are synced via
the **App State** protocol — encrypted LTHash-chained patches, historically one of the gnarlier
parts of any WhatsApp client implementation). In practice the vendored whatsmeow already ships
ready-made patch builders for all four: `appstate.BuildMute`, `BuildPin`, `BuildArchive`,
`BuildStar` (plus `BuildMarkChatAsRead`, `BuildSettingPushName`, `BuildDeleteChat`, `BuildLabelChat`
for free) — and sending one is a single call, `client.SendAppState(ctx, patch)`. So the Go-side
lift drops from "reimplement a sync protocol" to "call four existing builder functions." The
library's own `dispatchAppState`/`applyAppStatePatches` machinery already exists for consuming
patches that arrive from *other* linked devices (i.e., reflecting a mute set from the phone) —
this should mostly be "already wired for free" once the corresponding webOS-side event handler is
added, but that consumption path (which `events.*` type each patch dispatches, if any) hasn't been
verified against this app's event handler and should be checked before scoping.
UI is the bulk of the real work: swipe/menu actions per thread (mirroring the existing
Delete/React swipe pattern already in `ConversationList.js`), an "Archived" filter/section, pinned
threads sorting to the top, a per-message "star" toggle, and a "Starred Messages" view. Four
distinct affordances across two levels (thread, message) plus two new list views.

### Profile: push name / status text / own picture — S-M
`SetStatusMessage(ctx, msg)` exists directly (this *is* the WhatsApp "About" text, per its own
doc-comment). `SetGroupPhoto(ctx, jid, avatar)` is **generic on target JID** — the same call used
for group photos already works for the *own* profile picture (call it with the account's own JID);
no new whatsmeow code needed there at all. Push name specifically has a low-effort path too via
`appstate.BuildSettingPushName(name)` + `SendAppState` (same mechanism as chat actions above).
Needs one new "Edit Profile" screen (display name, about text, tap-to-change photo) — no such
screen exists today in the Accounts/WhatsApp validator UI, but it's a single focused form, not a
flow.

### Privacy settings & disappearing messages — M
`GetPrivacySettings`/`SetPrivacySetting(ctx, name, value)` already exist as direct calls
(presumably covering last-seen, profile-photo, about, status, read-receipts, groups-add — see
`types.PrivacySettingType` for the actual enumerated set). `SetDisappearingTimer(ctx, chat,
duration, settingTS)` and `SetDefaultDisappearingTimer(ctx, duration)` **also already exist
directly** — no need to hand-construct a `ProtocolMessage` as might be assumed; this is
meaningfully simpler than the `message-expiration` account-option workaround already sitting
unused in `send_message.go` (`GOWHATSAPP_EXPIRATION_OPTION` — never exposed in any webOS UI).
The one genuinely new piece of infrastructure: **disappearing messages only matter if expired
messages actually get removed locally** — WhatsApp servers don't retroactively purge already-
synced copies, so this needs a local timer/purge job against `immessage` rows, which doesn't
exist anywhere in this codebase today. That purge mechanism, not the protocol calls, is the
long pole here.

---

## Suggested prioritization

**Quick wins** (small, contained, no new UI paradigms) — do these first:
IsOnWhatsApp lookup, business profile display, outgoing typing indicator, block/unblock action,
own profile (name/status/photo), GIF send.

**Medium lifts** (backend mostly solved, meaningful but bounded new UI):
newsletter creation, chat actions (archive/pin/mute/star), privacy settings + disappearing
messages (incl. the local purge job), basic group create/admin/invite.

**Large, architecture-touching** (save for last, or scope as their own mini-projects):
communities (needs a new "collection of chats" concept in the app's data model), status posts
(needs a genuinely new full-screen UI paradigm — closer to a new feature than an extension).
