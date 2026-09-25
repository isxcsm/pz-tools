# Gameplay background load

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Base: dev `51c8db8`. Repository format 2 / schema 5 is unchanged. This branch reduces
avoidable work around a required save; it does not turn off saving, integrity checks,
USN fallback hashing, or durable restore writes. No game or user data is reset.

## Save is not optional optimization work

Active game backups continue to call GameWindow.save(true) on the game thread and
wait for the response before the initial/full/incremental file capture starts.
A failed or unknown completion still aborts the backup instead of pretending disk
state is complete. The existing explicit save-disabled setting is unchanged and is
not used as the performance solution. The user's reported memory-only vehicle data
is why skipping this call is not an acceptable default. Tests use synthetic memory-
only state flushed by save(true) and verify that both backup revisions restore it.
This is not a real-vehicle integration test or a guarantee about errors the game
itself catches inside its save routine.

## One bootstrap and dispatch hook

The helper still starts and uses Attach discovery. It loads the Java instrumentation
agent only if the JVM has no published bootstrap endpoint. Initialization is serialized
with a per-user OS file lock in ~/.pztools-bridge/bootstrap.lock, released on helper
exit; the zero-byte lock file is kept to avoid unlink/relock races. There is no retry
of an ambiguous accepted session. Failed endpoint communication requires investigation
or a game restart, not another loadAgent() that would create another JVM agent.

One random-credential loopback listener and one idle game-loop hook are retained per
JVM. Only the initialized payload path is accepted. Callback requests still authenticate
with a separate per-request random token and expected PID. Control request/response
sizes and socket wait times are bounded; it cannot evaluate arbitrary Lua or Java text.
One request session at a time may load a payload or own the game callback. The payload
archive is read from a closed bounded snapshot, hashed and reused when unchanged;
only one current payload loader is retained. A new payload hash swaps between requests.

Hook installation/retransformation is no longer repeated on each request. Idle poll
is a volatile read/null check with no filesystem/network work or synchronized block.
The active request still validates the world/path, runs the game's required save on
its thread, and handles deadlines, disconnects and cancellation. A save already running
keeps ownership until it returns even if the requesting process disappears. Other
agents can still retransform classes; their changes and our single dispatch must coexist.
Bootstrap changes require restarting the game; rebuilding just the app is insufficient
for a JVM that already loaded an old AgentEntry. Payload-only replacement at the same
path remains supported. Agent updates never rewrite the game's installation.

## Background work

Periodic StateScheduler ticks now run the Collector/Reactor pipeline in the existing
scheduler process. They keep the StateCollection named mutex, independent observation
debounce, durable pending-batch recovery, outbox delivery and live settings reload.
Periodic checks do not start Runner/Collector/Reactor processes. Explicit/manual
StateRunner calls retain their existing isolated process path and share exclusion.
Polling frequency and the gameplay evidence required for automatic backup are unchanged.
All discovered saves still receive activity/character checks; this change removes
process startup cost, not all polling SQL or file access.

Heavy automatic maintenance is deferred while any PZ process exists or process discovery
is uncertain. Menus are intentionally treated conservatively. The dispatcher avoids
starting heavy children and they recheck at entry. A one-second watcher requests
cooperative cancellation if the game starts later. Existing VACUUM native interruption
and transaction rollback remain. This is not instantaneous OS I/O cancellation: an
already running SQLite call or committed physical cleanup can finish before yielding.
Retention marking remains lightweight; disk reclaim, orphan cleanup and VACUUM may be
delayed until the game exits and the next periodic check runs. Orphan deletion policy
is unchanged, but actual reclaim latency can span an entire play session. Explicit
library/direct maintenance calls are not all automatically subject to this process gate.

Character display uses the players.db/WAL version, not the thumbnail version. Failed
reads retain the last good display and retry after 1, 2, 4, 8, 16, then 30 seconds;
changing file stamps does not bypass that retry delay. Removed saves release cache
entries. This cache does not determine gameplay activity or death-triggered backups.
BLOB parsing still happens when player data actually changes. Telemetry min/max cursor
bounds use separate indexed scalar subqueries, preserving empty/reset semantics without
a combined aggregate scanning all retained events.

## Verification and limits

GameSaveClientTests include 50 sequential real Attach/helper sessions in one synthetic
Java 25 JVM, save count, one payload loader/hook installation, idle ownership, another
agent's retransformation, payload hot replacement, cancellation and unauthenticated
control rejection. Synthetic memory-only data must be present after initial/incremental
backup and restore. Existing failure, countdown and world-mismatch tests remain required.
GameplayBackgroundTests cover mutex exclusion, interrupted state batches, activation/
exit debounce, maintenance deferral, cooperative cancellation, display cache backoff and
telemetry extrema. A published StateScheduler test uses an intentionally absent helper
directory to exercise the no-child-process periodic path.

Record actual Windows/Java/published-artifact results in the PR after execution. These
are not hours-long gameplay, native-memory plateau, GC/safepoint or frame-time measurements.
Mandatory save(true), helper startup/Attach property reads, reflection/path validation
while saving, all-save discovery, compression and stable-copy I/O still cost resources.
No FPS/stutter cure is claimed without a controlled real-game profile.
