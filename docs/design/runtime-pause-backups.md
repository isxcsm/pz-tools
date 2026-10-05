# Game-aware backup timing

[Documentation index](../README.md)

With **Delay scheduled backups while paused or asleep** on (`[backup].pause_periodic_during_game`, the
default), the periodic interval counts only active play, read live from the game through the
[game bridge](game-bridge.md). With it off, periodic backups follow the wall clock. This page covers how the
scheduler follows the game, what holds the countdown, what happens when the game cannot be read, and how a
failed attempt affects the next one. What the player sees is in
[backups](../reference/backups.md#when-automatic-backups-run).

## Pipeline

| Stage | Code | Does |
| --- | --- | --- |
| Observer, in the game | `RuntimeObserver`, `PzRuntimeAdapter`, `LiveCharacter` | Samples phase, pause, mode, save path, life and sleep on the game thread each frame; keeps the active-time clock |
| State stream | `RuntimeWatch` → `GameRuntimeClient` | Sends the latest snapshot every 250 ms |
| State scheduler | `RuntimeObservationCoordinator` | Keeps the stream connected, publishes an observation, commits semantic changes |
| State database | `StateDatabase.Runtime`, `RuntimeStateReactor` | Commits a changed observation and its outbox row in one transaction |
| Relay | `StateOutboxRelay` → `SchedulerDatabase.ApplyRuntimeTransitionAsync` | Writes `runtime_facts`, switches the target, queues death backups ([death backups](runtime-character-death.md)) |
| Feed | `RuntimeStateFeed` (named pipe, current user only) | Carries observations to the backup scheduler and the app |
| Backup scheduler | `RuntimeScheduleController`, `ActiveTimeSchedulePolicy`, `BackupScheduler` | Owns remaining time, issues tickets, starts workers |
| Display | `RuntimeScheduleProjection`, `GameLinkMonitor` | Builds the schedule line and the link card; never admits a backup |

The relay writes to `scheduler.db`, a different database from `state.db`, so it is at-least-once:
`ApplyRuntimeTransitionAsync` ignores a revision it has already applied, and the outbox row is deleted after.
The backup scheduler uses an observation only once `runtime_facts` holds the same revision and semantic key
(`CommittedObservation`); until then it sees `state-transition-pending`.

## Reading the game

`PzRuntimeAdapter` reads, by reflection on Build 42 classes:

| Value | Source |
| --- | --- |
| Phase | `GameWindow.states.current`: `IngameState` with a cell is `Ready`, without one `Loading`; `MainScreenState` is `Menu`; `GameLoadingState` is `Loading`; `Core.exiting` is `Unloading`; anything else `Unknown` |
| Pause | `GameTime.isGamePaused()`. A state yielded on top of the game (a debug tool such as the chunk viewer) counts as `Ready` and `Paused`. |
| Mode | `Networked` if `GameClient.client`, `clientSave` or `GameServer.server`; `Unsupported` if `Core.isNoSave()`, `LastStand` or `Tutorial`; else `LocalSinglePlayer` |
| Save path | `ZomboidFileSystem.getCurrentSaveDir()`, read once per world |
| Life, sleep | `IsoPlayer.getInstance()`, `isDead()`, `isAsleep()`, only when `IsoPlayer.numPlayers` is 1 |

The active clock (`activeMillis`) grows only between two samples that both have the world ready, unpaused and
the character not asleep. A sleep value that cannot be read is `Unknown`, which does not stop the clock: only
the sleep pause is lost. A gap of more than 2 s between samples, or a new world, starts a new clock epoch at
zero. A gap, a new world, a phase change or leaving the running state increments the eligibility epoch, which
invalidates tickets issued before it.

A snapshot is made on any change and at least every 100 ms. The stream sends the latest one every 250 ms with
its sample age, so a merged update cannot lose a pause and resume: the cumulative active time and the epochs
carry it. The client fails the stream if no line arrives for 2 s, if identities or the sequence change without
a reconnect, or if active time goes backwards within one clock epoch. An observation is fresh when both its
receipt and the game's sample are at most 2 s old; a live socket cannot make a stalled game thread look
current.

Transport and SQLite work stay off the game thread. `state.db` is written only on a semantic change; the
schedule checkpoint on a boundary change and at most every 10 s while the countdown moves.

## The countdown

`ActiveTimeSchedulePolicy.Advance` is a pure reducer from the previous state and the current observation.
It subtracts the growth of `activeMillis` since the last sample, but only while anchored to the same stream,
process, observer, world and clock epoch. Anything that breaks the anchor holds the countdown; the time
during the break is never counted. Game speed does not matter: the clock counts real time.

| Observation | Hold | Remaining time |
| --- | --- | --- |
| Fresh, world ready, running, awake | None | Counts down |
| Paused, or a debug tool on top | `GamePaused` | Kept |
| Asleep | `Sleeping` | Kept |
| Sleep unreadable | None | Counts down |
| Character dead | `CharacterDead` | Reset to a full interval while dead ([death backups](runtime-character-death.md)) |
| Before the first frame, loading, stale, `Unknown` phase | `Unknown` | Kept |
| Several game processes | `Ambiguous` | Kept |
| Multiplayer or a mode without saving | `Unsupported` | Kept |
| Main menu or unloading | `NoWorld` | Reset to a full interval |
| No game process | `GameOffline`, `NoWorld` | Reset, as the target is cleared (below) |
| A different world than before | None | Reset to a full interval |

When the observed world changes to another save, to the main menu or to no game, `ApplyRuntimeTransitionAsync`
switches the scheduler's target, increments the generation, deletes the checkpoint and any pending runs. A
new generation always starts a full interval. A reconnect to the same game keeps the remaining time: the new
stream only re-anchors.

Other things that start a full interval:

| Change | Mechanism |
| --- | --- |
| The interval, the main switch or the repository changes | Generation increment (`SchedulerDatabase.ConfigureBackupAsync`) |
| Game-aware timing is switched on or off | `runtime_options.enabled` changes and the checkpoint is deleted |
| The app starts | `AppHost` calls `RestartPeriodicScheduleAsync`, which increments the generation when automatic backups are on with a target |

A restart of only the scheduler process, inside a running app, reloads the checkpoint and keeps the remaining
time. A fallback due time is not kept: the restarted scheduler waits out the grace period again.

When a backup completes, the next slot keeps the cadence: an overdue slot does not cause catch-up backups
(`Complete` with `Consume`).

**Automatic backups** off holds everything, death backups included.

<a id="admission"></a>
## Admission

The countdown in the app is only a display. When the remaining time falls within the preparation lead
(`preparation_lead_seconds`, 8 s by default) and nothing holds, `RuntimeScheduleController` issues an
admission with a [ticket](glossary.md#ticket): process, observer, world, clock epoch, eligibility epoch, the
active time at which the backup is due, and an attempt id. The worker passes it to the game with
`SAVE_ACTIVE` (or `PROBE_ACTIVE` when **Save game before backup** is off).

On the game thread the ticket is checked every frame until the save starts (`RuntimeObserver.Ticket.check`):

| Check | Deferred as |
| --- | --- |
| Same process, observer, world, clock epoch and eligibility epoch | `runtime-epoch-changed` |
| World ready and local single player | `runtime-world-unavailable` |
| Not paused | `runtime-game-paused` |
| Not asleep | `runtime-character-asleep` |
| At most 60 s of active time left until due | `runtime-deadline-invalid` |
| The observer is still running and sampled within 2 s | `runtime-unavailable` |

The check returns the time left, and the save waits for it, so the game saves at the due moment of active play
even if the request arrived early. A deferral before the save starts does not use the slot.

The app side can also withdraw permission while the request waits: the worker polls
`RuntimePreparationPermit` and sends `CANCEL` (see [cancellation](game-bridge.md#cancellation)).
Cancellation and saving race on one compare-and-set in the game, so exactly one wins. A save that has
started completes.

Files are captured only after preparation succeeded or was skipped as unreachable.

<a id="when-the-game-cannot-be-read"></a>
## When the game cannot be read

Backups must not stop for good because the game cannot be read: a game update, a blocked helper or an
unrecognised state. Each game-dependent feature stops only for what it needs.

`RuntimeObservation.IsLinkUnusable` is true for:

- `Unknown` quality, except before the game's first frame (`game-starting`);
- `Stale` quality, except `game-busy`: frames still arrive but the game thread has not sampled for 2 s while
  outside a world, as when returning to the main menu reloads every mod;
- a fresh frame whose phase is `Unknown` (the game answers without a recognisable state).

A game still starting is a known state however long its first load takes: its observer samples on the main
loop, which first runs after the load. A game busy outside a world shows **Game is loading**. A stale sample
inside a world may be a hung game and counts as unusable.

| What is missing | What happens |
| --- | --- |
| The observation, for longer than the grace period (90 s, `RuntimeScheduleController.DefaultLinkGrace`) | `ApplyLinkFallback` sets `FallbackDueUtc` to now plus the remaining time. Periodic backups then follow the wall clock with the save the state check last confirmed active (`ReadFileDerivedTargetAsync`: the newest target command, if it is `ActivateTarget`). Each runs only while that save's `players.db` is locked (`isTargetActive`). The worker still passes `--save-game` with a due time, so it tries `SAVE_AT` first; if the game is unreachable it backs up the files on disk with a warning. When the game can be read again, the time left to the fallback due time becomes the remaining active time. |
| The save request channel | Nothing was asked of the game, so the backup goes ahead with the files on disk ([outcomes](game-bridge.md#admission-and-failures)). This applies to every kind of backup. |
| Sleep | The clock keeps running; pause still holds it |
| A bridge from before an app update | Periodic backups wait for a game restart, without a grace period ([restart required](game-bridge.md#restart-required-after-an-app-update)) |

During the fallback the schedule line shows **Next backup (game not connected)** and the link card
**Not connected to the game** with **Backups continue on a timer. If the game cannot save first, the files are
backed up as they are.** Neither says the game is not saved: each backup still tries `SAVE_AT`. The settings that need the game
(game-aware timing, death backups, save before backup, countdown) are locked meanwhile and keep their saved
values (`SettingsPage.UpdateAvailability`).

With game-aware timing on, the state check takes activity from the stream
([choosing the backup target](process-architecture.md#game-state-decisions)). While the stream is unusable
(`IsLinkUnusable`), it reads each save's `players.db` lock instead (`GameActivityLane`), so the save the game has
open still gets an `ActivateTarget` command. That keeps the fallback's target right when the game could not be
read from its start, as after a game update this PZ Tools cannot read. Those commands only feed the fallback:
game-aware timing does not apply file-derived commands to the schedule. A game still starting is a known state,
not a lost link, and is not guessed from files. `GameLinkFallbackTests` covers the path from the state check to
the target.

<a id="when-a-backup-attempt-fails"></a>
## When a backup attempt fails

The worker's result carries a `ScheduleDisposition`, which `RuntimeScheduleController.FinishAsync` applies:

| Disposition | When | Effect |
| --- | --- | --- |
| `Consume` | Success or no change; a known failure (the game reported an error, capture failed after the save, the worker could not start) | Next slot, cadence kept |
| `Preserve` | `runtime-deferred` or `queue-timeout` (worker reports `Skipped`); repository busy; an error before any worker was dispatched; a reservation that never reached its worker; an obsolete reservation | Same slot, tried again when admissible |
| `CompletionUnknown` | `completion-unknown` or `invalid-response` from the game; the guarded worker was cancelled; a dispatched worker's result is missing or malformed | Remaining time set to a full interval with `CompletionUncertain`; the hold shows **Skipping this backup** until that interval of active play has passed |

An unknown outcome is not retried at once because the game may still be saving. After one interval it has long
finished, and the next attempt is an ordinary one. The flag is in the checkpoint, so it survives a scheduler
restart. A scheduler that restarts with an attempt id in its checkpoint and finds the clock identity or
eligibility changed also treats that attempt as unknown.

Wall-clock fallback slots are moved on by `FinishFallbackAsync`; a busy repository without a started worker
keeps the slot due.

## Background processes

Extension control runs beside the state stream (`OptionalWorkSupervisor`) and cannot end it; its failure is
reported as `controller-failed` and retried on its own. The scheduler processes are restarted with backoff,
reported as faulted after repeated quick failures, and still retried about once a minute.

## Tests

Tests with a controlled clock, temporary databases and a synthetic game JVM cover pause and sleep,
reconnects, cancellation, settings changes and save-before-capture. They do not establish real-game frame
time, long-session behaviour or compatibility with every mod; use a disposable world for those.
