# contacts.plugin.messaging — BIG-HACK guard

Skips the redundant messaging re-association that the stock contacts linker plugin runs for
**already-associated** contacts on every re-link. On a messaging-heavy device this is the single
biggest per-contact cost in the linker — far bigger than the autolinker's ranking or the contacts
framework's fixup.

## Background

The contacts linker (`com.palm.service.contacts.linker`) dispatches to a plugin
(`contacts.plugin.messaging`, at
`/usr/palm/frameworks/contacts.plugin.messaging/submission/12.1/javascript/`) for every person it
adds or changes. That plugin links IM buddies (`com.palm.imbuddystatus`) and merges chat threads
(`com.palm.chatthread`) to the person.

`personChanged.js` contains a self-labelled **"BIG HACK"**: when a person arrives as a *change*
whose address set is unchanged (`old === new`) but non-empty, it assumes this is a UI-added contact
mis-classified as a change and runs the **full `personAdded()` association**. The problem: a
re-link / re-save of an **already-associated** person also arrives exactly this way, so the BIG HACK
re-runs the entire association (buddy lookups + chat-thread queries + merges) for contacts that are
already linked — pure waste.

Profiling a `forceAutolink` on a device with WhatsApp/Telegram/Signal buddies showed ~1.1 s/contact,
dominated by this plugin (not ranking, not fixup, not logging — gating the verbose logs saved only
~9%).

## The guard

Only run `personAdded()` when the person is **not already associated**. A `com.palm.chatthread` or
`com.palm.imbuddystatus` record carrying `personId === this person` can only exist from a **prior**
association, so its presence proves association already happened → skip. A genuinely-new person has
no such record → it still associates. **No false positives.** Both lookups are indexed
(`chatthread.byperson`, `imbuddystatus.byperson`), so the guard adds one cheap query to
`personChanged` (~11 ms) and, when it fires, removes a full `personAdded` (~350 ms).

Scope: this only affects the `personChanged` BIG-HACK path (re-link re-saves + UI single-adds). A
first-time bulk import dispatches via `personAdded` **directly**, so that necessary first-pass
association is untouched.

## On-device A/B (topaz, 2026-07-28)

Log-gated baseline (BIG HACK intact) vs the same + guard; only `personChanged.js` differs. Per-call
timers to a file; linker killed between runs to force a plugin reload.

| Metric                        | Baseline (BIG HACK) | Guarded        |
| ----------------------------- | ------------------: | -------------: |
| `personAdded` calls / contact | 1.00 (85/85)        | 0.13 (15/115)  |
| redundant re-associations     | all                 | 100/115 skipped |
| `personAdded` total time      | 30.6 s              | 4.2 s          |
| per-contact plugin work       | ~375 ms             | ~62 ms (−83%)  |

The 15 genuinely-unassociated contacts still ran `personAdded` and were correctly associated — no
association lost. Validated identically in a host harness (real plugin source + query-aware mock DB):
already-associated re-link 5→1 db8 round-trips; new person still associates.

## Install

    novacom -d topaz-linux run file:///bin/sh -- < install.sh

Ships the complete `personChanged.js` (guard only — no timer, stock logging). Backs up the original
to `personChanged.js.b4bighackguard`, and kills the linker so the guard loads on the next autolink.
Revert: restore that backup and kill the linker again.

## Related (not included here)

- `opt(b)` autolinker (parallel similarity reads) — verified on device (152 contacts, 0 mismatches),
  smaller real-world gain on a messaging-heavy device. Prototype in the session scratchpad.
- fixup backup-skip (contacts framework) — byte-identical in qemu on 439 real contacts; also a
  smaller real-world gain. Not shipped.
