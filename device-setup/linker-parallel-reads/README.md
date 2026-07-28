# contacts linker — opt(b) parallel similarity reads

Runs the autolinker's four similarity rankers concurrently instead of one-after-another, overlapping
their db8 read round-trips.

## Background

For each contact, `Autolinker.doRankingFunctions` scores candidate persons with four rankers —
`similarName`, `similarPhoneNumber`, `similarEmail`, `similarIM` — each of which issues a db8
`execute("batch")` query. Stock chains them **sequentially** with a `Future` `.then` chain, so it
pays four serial IPC round-trips per contact. The linker is IPC-round-trip bound (CPU ≪ wall), and
reads are ~85% of the round-trips, so this serialization is a real cost on a large import.

## The change

Run the four rankers concurrently via `Foundations.Control.mapReduce`, so their read round-trips
overlap (~4 serial → ~1). This is safe because:

- Each ranker only **adds** its own weight type to the shared `weightedResults` (via
  `addSimilarityToCurrentWeightForPerson` → `addWeight`, which is `this.weight += w`). Addition is
  commutative, so the final weights — and the link decision (`weight >= 100`) — are independent of
  the order the queries return.
- The read-modify-write runs **synchronously** inside each ranker's `.then` callback; node is
  single-threaded, so the updates never actually interleave.
- CLB `manualLinks` / `manualUnlinks` (which use MAX/MIN override weights) are kept **sequential and
  after** the similarity pass, exactly as in stock.

`mapReduce` gotcha handled: its data items must not be functions (internally it does
`map(data[i]).then(data[i], fn)`, and `Future.then` treats a function in the scope slot as the
callback). So we pass indices `[0, 1, 2, 3]` and dispatch through a `similarityRankers` array in
`map()`.

## Verification

- **Correct by construction** (commutative additive weights; decision is weight-only).
- **On device (topaz):** a self-comparing build ran both the parallel and serial rankings for every
  processed contact and logged any weight/decision mismatch — **152 contacts, 0 mismatches.**
- **qemu (real node 0.4.12):** ranking phase 68 ms → 35 ms (2.0×), weights byte-identical.

Honest scope: on a messaging-heavy device the dominant per-contact linker cost is the messaging
plugin (see `../contacts-messaging-guard`), so opt(b)'s real-world contribution is smaller than its
2× ranking speedup suggests — it helps the read-IPC portion of each contact.

## Install

    novacom -d topaz-linux run file:///bin/sh -- < install.sh

Ships the complete `autolinker.js`. Backs up the original to `autolinker.js.b4optb` and kills the
linker so it reloads on the next autolink. Revert: restore that backup and kill the linker again.
