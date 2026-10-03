# Gameplay background load

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

Historical implementation record based on dev `51c8db8`; format 2 / schema 5 was
unchanged. The work reduced overhead around game saving. See [game bridge](../game-bridge.md),
[configuration](../configuration.md) and [cleanup policy](../repository-housekeeping.md)
for maintained behavior and limits.

## Save is not optional optimization work

The optimization retained GameWindow.save(true) on the game thread before capture
when saving was enabled. Failed or unknown completion aborted the backup. Synthetic
memory-only state flushed by save(true) was verified after initial/incremental backup
and restore; that did not establish real-vehicle integration or cover errors caught
inside the game's save routine.

## One bootstrap and dispatch hook

The helper retained Attach discovery but loaded the agent only when no bootstrap
endpoint existed. A per-user OS lock at `~/.pztools-bridge/bootstrap.lock` serialized
initialization; keeping the zero-byte file avoided unlink/relock races. Ambiguous
accepted sessions were not retried with another loadAgent().

One authenticated loopback listener and game-loop hook remained per JVM. Requests
required the initialized payload path, a separate callback token and expected PID;
message sizes and waits were bounded. The endpoint could not evaluate arbitrary code.
One session owned the payload/game callback at a time. A closed, bounded archive snapshot
was hashed, reused if unchanged, or swapped between requests, retaining one payload loader.

Hook installation stopped repeating per request; idle polling became a volatile
read/null check. Active requests retained world/path validation and deadline/cancellation
handling. A running save kept ownership until return even if its caller disappeared.
The dispatch hook had to coexist with other agents' retransformation. Bootstrap changes
required a game restart; payload replacement at the same path did not.

## Background work

Periodic StateScheduler ticks moved Collector/Reactor work into the scheduler process,
retaining mutex exclusion, debounce, pending-batch recovery, outbox delivery and settings
reload. Manual StateRunner calls kept process isolation. Polling frequency and checks
for every discovered save were unchanged; the saving was process startup cost.

Heavy automatic maintenance was deferred while any PZ process existed, including menus,
or discovery was uncertain. Dispatch and entry checks prevented starts; a one-second
watcher requested cooperative cancellation if the game appeared later. SQLite work
could finish before yielding. Retention marking continued, while reclaim, orphan cleanup
and VACUUM could wait an entire play session. Direct/library calls were not all gated.

Character display keyed its cache to players.db/WAL versions. Failed reads retained
the last display and retried after 1, 2, 4, 8, 16, then 30 seconds, regardless of stamp
changes. Removed saves released entries. This cache did not drive activity/death detection.
Telemetry cursor bounds switched to separate indexed min/max subqueries, preserving
empty/reset behavior without scanning every retained event.

## Verification and limits

`GameSaveClientTests` covered 50 sequential Attach/helper sessions in one synthetic
Java 25 JVM, single-loader/hook reuse, payload replacement and session security/lifetime.
`GameplayBackgroundTests` covered state recovery, maintenance deferral and cache backoff.
A published StateScheduler fixture exercised periodic work with no helper directory.

This record contains no final Windows/JVM counts or long-running gameplay, native-memory
or frame-time measurements. Required saving, Attach discovery, polling, compression and
capture I/O still cost resources; the work did not establish an FPS or stutter improvement.
