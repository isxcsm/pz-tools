# Frame-budgeted backup save (0.13.0)

[Documentation index](README.md) · [Game extensions](game-extensions.md)

[Documentation index](README.md) · [Game extensions](game-extensions.md)

This fixes the measured 0.10 main-thread batching problem; it is not a claim that
uninterrupted real-game frame times have already been verified.

## Measured problem and the new boundary

The reported 42.20 run saved 361 chunks in one game-thread callback: 558 ms total
preparation, including 323.757 ms in chunk bodies and 162.227 ms in I/O handoff.
Moving only the final writes did not let the game loop run during those 558 ms.

The provider now returns a CooperativeCapture plan. The existing game-loop poll
uses the optional CooperativeTask.advanceOnGameThread capability to advance it,
with a 4 ms target. Ready chunk serializers and lightweight metadata stages share
the remaining budget; there is no fixed four-chunk limit per call. Normal
game logic/input/rendering runs between calls. No UI is pumped recursively and no
inventory/drag state is used as an admission condition. Other independent saves still
use the unmodified original entrypoints. A single serializer, metadata operation,
validation pass or contended original lock is not preemptible: 4 ms is a scheduling
target, not an absolute worst-case guarantee. The largest actual step is measured.

The optional contract lives in the replaceable extension runtime. Resident API 9,
extension API 2 and wire protocol 6 stay unchanged. No forced game restart is required
for an otherwise compatible, idle component update. The source graph is checked
before generated private phase entrypoints are used.

## Complete save coverage, split work

The verified private root is divided at closed-resource boundaries. Its original
metadata, OnSave, cell/animal/native/global/radio/map/entity and virtual-vehicle
operations are retained. The preview-only region is omitted. The cell's traversal
is supplied by the frame plan instead of invoking the entire loaded chunk grid.
No streams, intrinsic locks or half-executed Java call stacks cross a frame boundary.

Chunk byte serialization uses the game's hot-capture argument to avoid its inline
vehicle SQL writes. At final admission, every vehicle in the current loaded chunks
(not only occupied vehicles) is captured through VehiclesDB2.updateVehicle, followed
by player capture, updateMain and the original virtual-vehicle save. Post-capture DB
acknowledgements are still required. Serializer and vehicle-entry fingerprints are
checked. Java subclass overrides keep their virtual dispatch.

## File handoff without a game-thread future wait

Two path-affine I/O lanes prepare bounded file baselines under the original counted file locks.
The game thread waits by returning to the next frame, not by calling Future.get().
Once ready, it serializes and copies the input; file locking, opening, hashing and
writing then run on the same lane as preparation and cleanup. Before writing, both the pinned file and current
path must still match the captured SHA-256 baseline. If an ordinary save won the
race, old bytes are not written; the plan requests a fresh capture.

There are at most 32 pending tickets. Half of the 64 MiB ownership budget is reserved
for copied output and half for membership checks. Each lane owns a reusable hash
buffer and digest. Newly created chunk files retain immediate vanilla
publication; that path and original lock contention can still take synchronous time.
Failure after admission is not silently retried as a standard full save.

Ready tickets are consumed before refilling the bounded preparation window. An
unready ticket does not block other ready chunks, and a pass with no progress
returns to the game loop instead of spinning. The plan reuses its identity map
and unchanged chunk records, but still enumerates loaded chunks on each capture
pass and checks coordinates, load IDs, dirty flags and membership. Reuse does not
cache away validation. Normalized paths always select the same single-thread lane;
two writers cannot reorder preparation, writing or cancellation cleanup for the
same path. The 32-ticket and byte bounds are shared, not doubled for two lanes.

Readiness remains mandatory before chunk serialization, cell saving and final
capture: the original serializers share a global lock/buffer, and queued ordinary
writes must not be ignored. While readiness is false, the plan can fill its bounded
file-baseline window without serializing chunks or advancing metadata stages. A
full window is not scanned again on each blocked callback. After readiness returns,
loaded-chunk identity and the baseline fences are still rechecked.

## Transfers and lifetime

Each captured chunk keeps structural membership checks for grid/object lists,
containers, nested inventories and loose world items. Loaded chunk identity/load ID,
dirty flags and membership are revalidated before final player/vehicle capture in
the same game-thread turn. Changed chunks are recaptured; removed/reused chunks lose
their old tickets. This protects the checked transfer relationships while yielding.
It is NOT an atomic world snapshot or validation of arbitrary third-party mutation
and all mutable scalar item properties. The backup source is still the live save
folder. These limits are not presented as stronger guarantees.

Continuous changes can prevent convergence: the plan fails after bounded retries
or a 60-second capture deadline rather than pausing UI or declaring a partial backup
successful. Changed worlds/characters and observed errors abort further capture.
Already admitted file/native/DB tasks retain ownership through cleanup. Module
replacement remains blocked until that lifetime ends.

## Diagnostics and acceptance

The existing card now shows the **longest uninterrupted game-thread save step**,
not accumulated work spread across frames. Detailed receipts keep cumulative
captureMs, maxCaptureSliceMs and captureStatsV1 (total microseconds, maximum slice
microseconds, step count), as well as original chunk/native stage aggregates.
Neither the card nor these counters are a renderer/FPS profiler.

Since 0.12.0, diagnostics are formatted only at capture completion/abort and after
cleanup, not on every game-loop callback. In 0.13.0 the runtime report is bounded to 4096
characters. Additional comma-separated counters are:

| Field | Values, in order |
| --- | --- |
| `captureGapStatsV1` | Total and maximum gap between capture callbacks, microseconds |
| `captureYieldStatsV1` | Budget yield count and gap microseconds, file yield count and gap microseconds, readiness yield count and gap microseconds |
| `completionStatsV1` | Completion-worker queue delay, commit duration, cleanup duration, microseconds |
| `completionWaitUs` | Residual file, native, database waits, including cleanup, microseconds |
| `dbAckUs` | Player and vehicle receipt elapsed time since arming, microseconds; -1 if no receipt |
| `chunkIoStatsV1` | Preparation count, store count, summed queue delay, preparation service time, store service time, file-lock wait time; durations in microseconds |
| `nativeStatsV1` | Start and receipt elapsed time since the owned request, game-thread handoff wait; microseconds, -1 for a missing start/receipt |
| `bridgeAdmissionStatsV1` | Provider-not-ready observation count and time from its first blocked check until ready, microseconds; before capture starts |
| `readinessStageStatsV1` | Count/gap-microsecond pairs for chunk, cell and final capture readiness |
| `readinessReasonStatsV1` | Count/gap-microsecond pairs for database unavailable, chunk worker unavailable, chunk saving, queued chunks, native unavailable, native saving, unknown |
| `readinessPrefetchV1` | Baseline tickets prepared while blocked, game-thread preparation microseconds (not the asynchronous file reads) |
| `chunkIoDetailStatsV1` | Preparation open, baseline hash, pinned-file rehash, pre-write path verification, write, output hash, post-write path verification, pinned-channel close, fresh-file synchronous write; microseconds |

Yield gaps include normal game-loop scheduling, not just the reason that caused
the yield. File-lock wait is already included in preparation/store service time.
DB/native receipts overlap capture and other work; residual completion waits are
not the full operation duration. These fields must not be added together as
independent wall-clock phases. Simultaneously observed readiness reasons each get
the same gap attribution, so reason totals can overlap. The I/O services now also
overlap across two lanes. Path verification includes opening/reading/hashing/closing
the current path; those sub-operations are not individually instrumented. An I/O
phase counter includes attempted work even when it fails or is cancelled.

The bridge bounds UTF-8 diagnostic bytes before Base64 encoding and marks truncation.
Successful receipts keep the existing `source.prepare.completed` detail. Optional
failure diagnostics travel inside the existing ERROR envelope but are separated
from the short exception message by the client. Failure telemetry records them in
a bounded, source-path-redacted `diagnostics` field; older message-only errors
remain compatible. Readiness timeout/withdrawal translated into a deferred automatic
backup preserves that field in `run.cancelled` with `code=source-deferred`; its
Cancelled/Skipped outcome and Warning severity are unchanged. Timeout and cancellation
reports are partial observations, not completion receipts. No per-frame or per-file
log stream is added.

Existing harnesses cover a real 361-chunk frame plan, blocked file preparation,
transfer recapture with final inventory reconciliation, newer ordinary file writes,
budget-failure cleanup and world exit. The connected backup test uses multiple game
callbacks before initial/incremental backup and restoration. Installed-JAR validation
creates the production phase graph and verifies original save bodies remain intact.
No synthetic result substitutes for measuring the same actual game world again.

No release ZIP is built for this change. Build the source with matched app/workers
and compare maximum-step time as well as total elapsed time. Synthetic throughput
does not establish real-game latency or a strict 4 ms maximum.

## Verification performed for 0.11

Windows Release solution/WinUI/native/Java build: zero warnings and errors.
The final frame-save.trx records 66 passed, zero failed, zero skipped tests.
Four existing Java harness entrypoints passed, including the 361-chunk actual plan,
late normal-write conflicts and budget-failure resource release. The production
phase graph initialized against the installed game JAR in a separate JVM; five
original save bodies remained unchanged, and three replacement loaders retired.
No live game save, user data mutation, distribution publish or ZIP creation was run.

## Indexed game collections (0.11.1)

The first 0.11 membership traversal assumed every game List supported iterators.
B42.20 IsoGridSquare.getObjects returns PZArrayList, whose iterator methods throw
UnsupportedOperationException; its inherited toArray also uses that unsupported
iterator. This made a normal loaded square fail capture before completion.

Membership capture now reads size/get into the retained snapshot array and traverses
that array for world objects and nested inventories. Identity, order, collection
replacement and size checks remain active; no game collection is modified.

The regression first reproduced the same exception against the unmodified 0.11
sources. The existing 361-chunk frame test now uses indexed-only collections and
passes with the fix, alongside the other three Java harness entrypoints. The
installed-JAR verifier also exercises the actual PZArrayList utility in a separate
JVM, confirming capture and change detection without starting a world or saving.
This does not replace the real-game acceptance procedure above.

Bridge errors now retain the original exception and a bounded throw-site/cause
summary, including exceptions with no message. The existing failure code and
no-replay behavior are unchanged; failed saves still do not create a backup revision.

The 0.11.1 Debug solution build completed with zero warnings/errors. The targeted
bridge, save-pipeline, backup-preparation and extension suite recorded 75 passed,
zero failed and one skipped explicit live-game probe in `indexed-list-bridge.trx`.
The transport fixture verifies that a message-less failure reaches the app with
its throw site and does not replay a standard save. Both corrected JARs in the
Debug app's worker directory matched the tested build by SHA-256.

## Throughput regression coverage (0.12.0)

The existing Java harnesses cover a pre-prepared 32-ticket window with one reused
chunk/load ID: the remaining 31 ready chunks can advance in one generously
budgeted call. A separately exhausted budget returns without draining all chunks.
Metadata callbacks that move items require recapture, and a callback that leaves
the world aborts before final admission. The 361-chunk runtime fixture still uses
the production 4 ms target; its observed chunk count per call is diagnostic, not
a timing assertion or a real-game frame-rate claim.

The runtime harness also checks that diagnostics are not formatted on incomplete
capture steps, contain post-cleanup values, and stay within the report limit.

The final Debug solution build completed with zero warnings/errors. All four Java
harness entrypoints passed. The .NET suite recorded 989 passed, zero failed and
28 skipped in `artifacts/test-results/seamless-throughput/seamless-throughput.trx`.
The skips require explicitly enabled live/USN/sample or published-distribution
environments; this run enabled the synthetic Java bridge fixtures only. The
installed-game verifier admitted the production adapter in a separate JVM,
confirmed unchanged original save bodies and retired three replacement loaders.
The Debug app's staged bridge/bootstrap/runtime/module JARs, catalog and backup
engine matched the tested outputs by SHA-256. No live game save, user-data change,
release publish or ZIP creation was performed.

## Two-lane I/O and diagnostics verification (0.13.0)

Verified from the isolated `fix/seamless-save-io-tracing` worktree on 2026-09-27.
The final Debug x64 solution build completed with zero warnings/errors. All five
Java harness entrypoints passed, including independent-path overlap, same-path
FIFO, cancellation, newer vanilla-write conflicts, shared queue/byte bounds,
world exit and retirement. Readiness tests retain the serialization barriers and
verify bounded baseline preparation during blocked frames.

The final .NET suite recorded 995 passed, zero failed and 28 explicitly gated
environment-dependent skips in `artifacts/test-results/seamless-io-final/seamless-io-final.trx`.
Coverage includes preparation timeouts, failure diagnostics, bounded Korean/emoji
transport, initial/incremental deferred backup diagnostics through the app log
projection, and unchanged revisions/checkpoints when preparation is declined.

The installed-game verifier admitted the production adapter in a separate JVM,
confirmed unchanged original save bodies and retired three replacement loaders.
The Debug app's staged bridge/bootstrap/runtime/module JARs, catalog and affected
worker DLLs matched the tested build outputs by SHA-256. Documentation checks passed.

Only the separate worktree's Debug output was built. The shared dev checkout and
vehicle worktree were not changed. The user's app recording configuration remains
Trace; the repository's default is unchanged. No app launch, real-game save, user
save mutation, release ZIP or push was performed. Real-game completion time and
frame-time improvement still require comparison in the same world with 0.13.0.
