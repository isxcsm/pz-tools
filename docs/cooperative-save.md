# Frame-budgeted backup save (0.11)

[Documentation index](README.md) · [Game extensions](game-extensions.md)

This fixes the measured 0.10 main-thread batching problem; it is not a claim that
uninterrupted real-game frame times have already been verified.

## Measured problem and the new boundary

The reported 42.20 run saved 361 chunks in one game-thread callback: 558 ms total
preparation, including 323.757 ms in chunk bodies and 162.227 ms in I/O handoff.
Moving only the final writes did not let the game loop run during those 558 ms.

The provider now returns a CooperativeCapture plan. The existing game-loop poll
uses the optional CooperativeTask.advanceOnGameThread capability to advance it,
with a 4 ms target and at most four chunk serializers per call. Normal
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

One I/O worker prepares bounded file baselines under the original counted file locks.
The game thread waits by returning to the next frame, not by calling Future.get().
Once ready, it serializes and copies the input; file locking, opening, hashing and
writing then run on the I/O worker. Before writing, both the pinned file and current
path must still match the captured SHA-256 baseline. If an ordinary save won the
race, old bytes are not written; the plan requests a fresh capture.

There are at most 32 pending tickets. Half of the 64 MiB ownership budget is reserved
for copied output and half for membership checks. A single reusable hash buffer is
confined to the I/O worker. Newly created chunk files retain immediate vanilla
publication; that path and original lock contention can still take synchronous time.
Failure after admission is not silently retried as a standard full save.

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

Existing harnesses cover a real 361-chunk frame plan, blocked file preparation,
transfer recapture with final inventory reconciliation, newer ordinary file writes,
budget-failure cleanup and world exit. The connected backup test uses multiple game
callbacks before initial/incremental backup and restoration. Installed-JAR validation
creates the production phase graph and verifies original save bodies remain intact.
No synthetic result substitutes for measuring the same actual game world again.

No release ZIP is built for this change. Build the source with matched app/workers
and compare maximum-step time as well as total elapsed time; total completion may
increase because the game now runs between capture steps.

## Verification performed

Windows Release solution/WinUI/native/Java build: zero warnings and errors.
The final frame-save.trx records 66 passed, zero failed, zero skipped tests.
Four existing Java harness entrypoints passed, including the 361-chunk actual plan,
late normal-write conflicts and budget-failure resource release. The production
phase graph initialized against the installed game JAR in a separate JVM; five
original save bodies remained unchanged, and three replacement loaders retired.
No live game save, user data mutation, distribution publish or ZIP creation was run.
