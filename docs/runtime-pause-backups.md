# Runtime observation and pause-aware periodic backups

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

This feature observes local single-player gameplay through the existing Java 25 agent.
It does not infer pause from players.db sharing, and it does not remove the required
GameWindow.save(true) before file capture. No game JAR or original save is modified.

## Behavior and settings

`[backup].pause_periodic_during_game` defaults to true. Settings exposes it separately
from automatic backups, pre-backup game saving and the in-game notice. A five-minute
interval with two minutes of active play retains three minutes during pause; resume
continues those three minutes. Faster game speeds do not accelerate this real-time
interval. Menu/exit clears the world target. Loading, unsupported modes, stale samples,
multiple games and disconnected observation hold rather than assume Running.

This option affects periodic backups. Explicit manual and death-triggered backups keep
their separate policies. Disabling automatic backups still takes precedence; resume
cannot enable them. An interval/policy change starts a new interval, frozen if paused.
As before, a new app launch rearms its interval; a worker restart/reconnect preserves
its checkpoint instead. Missed active-time slots do not cause a burst of catch-up saves.

Disabling pre-backup saving alone no longer promises that JVM observation is disabled.
With pause-aware timing enabled, guarded PROBE still observes the world and waits for the
active deadline, but never calls save. This explicit save-disabled option remains less
complete: data only in game memory may be absent from the backup. Saving is on by default.
To deliberately use the old file-lock/wall-clock path, turn off the pause-aware option.
A broken observer never silently falls back to that path while the option is enabled.

## Ownership and dependency boundaries

- Process.Contracts/GameRuntime contains bounded typed snapshots, identities, tickets,
  hold reasons and schedule dispositions. It has no Java or database dependency.
- Java PzRuntimeAdapter contains game-version-specific field/getter knowledge.
  RuntimeObserver owns a latest snapshot and cumulative active-time clock; RuntimeWatch
  sends it without blocking the game thread. SaveBridge owns the separate save slot.
- SaveBridge/GameRuntimeClient authenticates and validates the stream, while the
  State.Scheduler composition root owns discovery, reconnects and the published feed.
- Zomboid.State owns path resolution and pending observation reduction. Semantic
  projection changes and the outbox commit in one transaction. The existing relay applies
  them idempotently to scheduler facts before acknowledging them.
- Scheduling owns the pure ActiveTimeSchedulePolicy, checkpoints, admissions and policy
  generation. Backup.Cli composes the game adapter with the existing preparation callback.
  The generic backup engine only knows a typed pre-capture deferral, not JVM pause APIs.
- Projections and WinUI render remaining time and a hold reason. Display estimates cannot
  issue an admission. State discovery and character metadata remain independent.

## Stream and clock contract

Each authenticated stream starts with its full snapshot. Frames contain process session,
observer epoch, world session, clock epoch, eligibility epoch, sequence, phase, pause,
mode, speed level, cumulative active milliseconds and game-sample age. Windows paths
are normalized at ingress without probing the filesystem. Reverse sequences or backwards
active time in one clock are rejected. Duplicate sequence content must be identical
apart from sample age. This is a latest-value feed, not a history of every event.

Known pause/resume effects survive coalescing through cumulative active time and eligibility
epoch changes. The game thread samples through the existing stable loop hook. Only state
changes or 100 ms checkpoints allocate a snapshot; the sender transmits at 250 ms. Getter
lookups are cached, path lookup is per-world, and network/JSON/SQLite are outside that thread.
A gap beyond two seconds creates a new clock epoch rather than charging unknown time.
Unknown samples break time continuity; reconnection reanchors the saved remainder.
The same in-memory world keeps its identity across observation reconnects through a weak
reference, without retaining a departed world or an obsolete payload class loader.

Transport receipt freshness and game-sample freshness are separate. A live socket cannot
make a frozen game thread current. The local read-only named-pipe feed is user/elevation
scoped, limited to four clients and 64 KiB frames, with bounded write/read deadlines.
No arbitrary method evaluation, scripts, subscription plugins or broker are introduced.
Only semantic state boundaries and slow ten-second checkpoints touch SQLite; heartbeat
updates are in memory. Deadlines and remaining time do not compare JVM nanotime with UTC.

## Save-start boundary and recovery

Guarded SAVE_ACTIVE/PROBE_ACTIVE carry an observer/world/clock/eligibility ticket,
an active-time due value, request ID and increasing command sequence. The game rejects
replayed tickets. Immediately before the saving CAS and invocation, the game thread
checks the world, pause, epochs and due time. The original RecoveryStamp and save(true)
sequence is preserved, and capture still begins only after preparation returns.

During preparation the worker reads its scheduler generation through a narrow read-only
permit. A changed setting can send CANCEL(request ID). The same atomic state transition
arbitrates cancellation against saving: cancellation that wins produces pre-save deferral;
a save that already started completes normally. Observation teardown similarly cancels
queued requests without taking the save monitor or interrupting the game's call.
RUNNING means preparation accepted; SAVING is a distinct phase, not a capture completion.

A pre-save deferral is a normal skipped workflow with Preserve disposition. It creates
no backup revision/checkpoint and does not consume the periodic slot. The internal run
is Cancelled/source-deferred without failure telemetry. The process envelope and runner
preserve the disposition explicitly rather than parsing an English error message.
A returned successful save is followed by the normal capture. A missing/failed completion
is conservative CompletionUnknown and blocks implicit retry in that schedule generation.
After checking the result, the user may rearm with the automatic-backup setting. A restarted
scheduler with an outstanding request and a different observer epoch also refuses replay.

## Compatibility and validation

Repository format 2 / schema 5 is unchanged. Additive state.db schema 4 and scheduler.db
schema 5 store runtime facts/checkpoints; their existing newer-version guards remain.
Do not reset the game save or backup repository. App, schedulers, worker and bridge payload
must come from one build. Bootstrap endpoint version 2 and save protocol 5 require fully
restarting a game that loaded the previous bootstrap. Runtime payload replacement while
observation or another command holds it is refused, not half-applied.

Tests use controlled clocks, isolated SQLite databases, named-pipe teardown and the
existing synthetic Java 25 fixture. The end-to-end guarded test preserves memory-only
fixture data through initial/incremental backup and restore, and checks that pause creates
no revision. Real-game frame time, hours-long memory use, mod compatibility and actual
vehicle persistence are not implied by synthetic tests. The observer samples frame
boundaries rather than claiming hard real-time or exactly-once game execution.
## Shared runtime after game-extension integration

The integrated bootstrap owns one observer and one save dispatch hook. Pause-aware
scheduling, game-version display and extension admission consume the same runtime.
Turning pause-aware scheduling off changes scheduling policy, not the shared
observer's lifetime. Extension cards do not create additional game subscriptions.
Protocol 6 combines guarded saves with optional provider selection; overrides of a
module's declared version range never override pause/epoch/cancellation checks.
See [Game extensions](game-extensions.md) for version ranges and remaining save work.
## Sleeping characters and countdown presentation

The existing pause-aware option (enabled by default) now also suspends periodic
backup time while the single local character is asleep. The game-thread observer
uses the cached IsoPlayer.isAsleep getter; sleep is an independent Unknown/Awake/Asleep
fact, not an inferred speed level, DB flag or change to the game's pause state.
STATE4 adds this fact to the existing stream. Older frames decode sleep as Unknown,
which holds periodic scheduling until an updated observer provides a known state.
No second watcher, process, per-frame file read or new bootstrap API is introduced.

Asleep/unknown intervals do not add to the active clock. Waking resumes the remaining
interval without multiplying it by accelerated game time or resetting it to the full
configured interval. A guarded periodic save rechecks sleep immediately before capture
and during preparation. Manual and death-triggered saving retain their separate rules;
an already executing save is not interrupted. Disabling the pause-aware option still
selects the explicit wall-clock policy and also disables sleep-aware countdown holds.

The sidebar presents a confirmed absent game process as "Game is not running" with
no remaining time. This holds even while its scheduler transition is still committing
and when the pause-aware option is disabled. Unknown/disconnected observation is not
misreported as offline. A running game at its menu is also distinct from no process.
Paused, sleeping or unknown-state countdowns retain their actual remaining value and
use the disabled text brush with a gentle 2.6-second opacity cycle. The animation is
not recreated on every state sample, respects Windows animation preferences, and is
stopped on resume, hidden countdown or shell unload. UI presentation cannot reserve
or execute work.

Validation covers typed frame/JSON round trips, unknown state, scheduler restart during
sleep, offline presentation before state commit, and a synthetic Java 25 game which
sleeps at accelerated speed, rejects a pending periodic save, permits a manual save,
and resumes its clock after waking. Actual WinUI interaction and a real game sleeping
session are not implied by these automated checks. Existing user settings and saves
are not reset or modified by the fixtures.
