# Process architecture

[Documentation index](../README.md)

The app window does no backup work itself. It starts two long-running schedulers, and they and the app start
short-lived runners and workers. Each process is a separate executable in the app folder, so a crash, a hang or a
Windows block on one of them leaves the others running. The [overview](overview.md) places these processes in the
whole system; this page is the reference for how they are started, what they lock and what they own.

## The processes

| Executable | Started by | Lifetime | Job |
| --- | --- | --- | --- |
| `PzTools.App.exe` | The player | Session | Window, tray, settings, progress cards. Starts and supervises the two schedulers. |
| `PzTools.Backup.Scheduler.exe` | App | Session | Decides when an automatic backup is due, starts the backup runner, then the maintenance runner. |
| `PzTools.State.Scheduler.exe` | App | Session | Finds the active save, keeps the game's state stream ([WATCH](glossary.md#watch)) open, controls the game extensions, dispatches the orphan-backups lane. |
| `PzTools.Backup.Runner.exe` | Backup scheduler (automatic), app (manual backup) | One backup | Takes the repository mutex and runs one backup worker. |
| `PzTools.Backup.Cli.exe backup` | Backup runner | One backup | The backup worker: asks the game to save, captures changed files, commits a revision. |
| `PzTools.Maintenance.Runner.exe` | Backup scheduler, after a backup that succeeded or changed nothing | Short | Takes the dispatch and repository mutexes and runs maintenance dispatch. |
| `PzTools.Maintenance.Cli.exe --dispatch-lanes true` | Maintenance runner | Short | Marks automatic backups beyond retention as deleted, then starts the heavy lanes detached. |
| `PzTools.Maintenance.Cli.exe --lane <lane>` | Dispatch or state scheduler, detached | Until done | One heavy [maintenance lane](#maintenance-lanes). |
| `PzTools.State.Runner.exe` | App (manual refresh) | One check | Runs `PzTools.State.Collector.Cli.exe` and `PzTools.State.Reactor.Cli.exe` as children. |
| `PzTools.Backup.Cli.exe restore` | App | One restore | Restores a revision into a save folder. |
| `PzTools.Zomboid.Archive.Cli.exe` | App | One operation | `inspect`, `export`, `export-live` and `import` of ZIP archives. |
| `PzTools.Zomboid.Recovery.Cli.exe` | App | One operation | [Character recovery](character-recovery.md). |
| `PzTools.Profiler.Cli.exe` | App | One recording or command | `record`, `roll-start`, `roll-save`, `roll-stop` ([profiler](profiler.md)). |
| `game-bridge\runtime\bin\java.exe` | Every game client (state scheduler, backup worker, profiler, app) | One connection | The attach helper that loads the [game bridge](game-bridge.md) into the game and connects it back over loopback. |

The app finds these executables only in its own folder
([`AppWorkerDirectoryResolver`](../../src/PzTools.App.Core/AppWorkerDirectoryResolver.cs)). A Debug build also
accepts `PZTOOLS_TOOLS_DIR`. A Release build ignores it, because the workers run as administrator and any program
of the player's could set the variable.

Every worker executable answers `--probe` by exiting with 0 and doing nothing else. The app probes all of them,
and the bundled `java.exe -version`, when it starts and then every 6 hours, or every 5 minutes while something is
blocked; a probe that takes longer than 15 seconds does not count as blocked ([`ComponentLaunchCheck`](../../src/PzTools.App.Core/ComponentLaunchCheck.cs)). Windows
application control can refuse one executable and not another, and its verdicts change from day to day. A refused
start is classified as `launch-blocked` (Win32 errors 225, 1260, 4551 and 4552), not `launch-failed`, and shows
on a card.

`PzTools.Backup.Cli.exe` and `PzTools.Maintenance.Cli.exe` without these arguments are also the command-line
tools; [command line](../reference/command-line.md) lists their commands.

### Command lines the app uses

The app starts the schedulers with these arguments
([`AppHost.StartCoreAsync`](../../src/PzTools.App.Core/AppHost.cs)):

```text
PzTools.Backup.Scheduler.exe run --scheduler-db <data>\scheduler.db --worker-directory <app>
    --control-db <data>\control.db

PzTools.State.Scheduler.exe --runtime-root <data> --scheduler-db <data>\scheduler.db --state-db <data>\state.db
    --saves-root <Saves> --repository <backup folder> --worker-directory <app> --control-db <data>\control.db
    --app-run <32 hex digits>
```

`<data>` is `%LOCALAPPDATA%\PzTools`. `--app-run` is [`AppRun.Id`](../../src/PzTools.App.Core/AppRun.cs), made
fresh at each app start; the game ties the app run's [lease](glossary.md#lease-app-run) to it.

The backup scheduler starts the runner with `--repository`, `--source-id`, `--save-game`,
`--require-active-game`, `--source <key>=<path>`, `--run-index`, `--worker-directory`, and either
`--scheduled-utc` or, for a game-aware backup, `--runtime-authority`, `--runtime-generation` and
`--runtime-ticket` ([`RunnerProcessAdapter`](../../src/PzTools.Scheduling/RunnerProcessAdapter.cs)). A manual
backup from the app passes the same repository and source arguments with `--save-game` but without
`--require-active-game`. Both add `--game-version` when the game reports one for that save; the manual
backup otherwise passes the version last seen with the save, or the one its newest backup recorded.

### Results and exit codes

Every runner and worker writes one JSON result envelope to standard output
([`ProcessContracts.cs`](../../src/PzTools.Process.Contracts/ProcessContracts.cs)): version 1, component, run index,
outcome, start and end times, a result, and an error code and message for `Failed` and `Cancelled`. The parent
validates it ([`ProcessResultValidator`](../../src/PzTools.Process.Contracts/ProcessResultValidator.cs)): no
parseable envelope becomes `invalid-process-result`; a different component, a different run index, or an exit code
that does not match the outcome becomes `process-contract-mismatch`. Exit code 64 is accepted with `Failed`. When
standard output holds more than the envelope, the last non-empty line is parsed.

| Outcome | Exit code |
| --- | --- |
| `Succeeded`, `NoChange`, `Skipped` | 0 |
| `Failed` | 1 |
| `Cancelled` | 2 |
| `Degraded` | 3 |
| Invalid arguments | 64 |
| `Busy` | 75 |

A scheduler that finds its own mutex taken exits with 75 at once.

## Databases

| Database | Location | Written by | Holds |
| --- | --- | --- | --- |
| `control.db` | `<data>` | Whoever needs a run index | One counter: the [run index](glossary.md#run-index) sequence ([`RunIndexAllocator`](../../src/PzTools.Control/RunIndexAllocator.cs)) |
| `scheduler.db` | `<data>` | App (backup settings), backup scheduler, state scheduler | Backup target, interval, on/off, next due time, pending runs, the command inbox, and the game-aware timing tables (`runtime_*`) |
| `state.db` | `<data>` | State scheduler, state runner's children | Pending collection batches, per-save debounce state, current game and save state, transitions, the outbox to the scheduler, and the game's runtime state (`runtime_*`) |
| `repository.db` | Backup folder | Backup worker, maintenance, restore, the app's delete and rename actions | Sources, revisions, catalog, packs, [workflows](glossary.md#workflow); see [repository format](repository-format.md) |
| `telemetry.db` | Backup folder | Backup worker | Detailed backup-engine runs and events |
| `.pztools\<component>\telemetry.db` | Beside the identity it belongs to | Its one component | Process telemetry; see [telemetry](telemetry.md) |
| `logs.db` | `<data>` | App | The Logs page's entries |

<a id="which-database-holds-what"></a>
The run index is allocated in one immediate transaction as
`max(last + 1, UTC Unix milliseconds × 65536, minimum)`
([`RunIndexAllocator`](../../src/PzTools.Control/RunIndexAllocator.cs)). It therefore grows across the installation
and does not go backwards when `control.db` is deleted and created again. A missing `control.db` is created; one
that cannot be opened or has another schema fails the run. There is no fallback to a counter in `state.db` or the
repository. A child process is given its run index on the command line and does not allocate another. A runner
started without `--run-index` allocates one before it tries `RepositoryAccess`, so an attempt that ends `Busy`
still uses up a number.

`control.db` refuses any schema version other than 1. `state.db` (schema 4) and `scheduler.db` (schema 5) refuse a
newer schema without changing it and migrate older ones forward.

The state scheduler and the app keep one read connection to `scheduler.db` and `state.db` open
(`HoldReadConnection`), because they read them every second; the app also keeps one to `repository.db`. The
backup scheduler opens a connection per access.

## Locks

All mutex names come from
[`NamedMutexRunner.CreateName`](../../src/PzTools.Process.Hosting/NamedMutexRunner.cs):
`Local\PzTools.<scope>.<SHA-256 of the upper-cased full path>`. Every acquisition is a single `WaitOne(0)`: nobody
waits for a mutex. A mutex abandoned by a dead process counts as acquired and is reported as `WasAbandoned`.
`AppInstance` is the exception: the app holds a handle to it, and a second launch finds it already created.

| Scope | Identity | Held by | Effect |
| --- | --- | --- | --- |
| `AppInstance` | Data folder | App, for its whole life | Second launch signals `AppActivate` (an event) to show the first window, then exits |
| `BackupScheduler` | `scheduler.db` | Backup scheduler | One backup scheduler per data folder |
| `StateScheduler` | `scheduler.db` and `state.db` | State scheduler | One state scheduler per data folder |
| `StateCollection` | `state.db` | Every state write: periodic check, runtime state commit, state runner, and the collector and reactor programs when run on their own (the state runner passes `--runner-holds-lock` to its children) | State writes never overlap |
| `RepositoryAccess` | Backup folder | Backup runner, maintenance runner, orphan-backups lane, restore, ZIP export of a backup, `verify`, character recovery, the app's delete and rename actions, start-up recovery | One job per repository at a time; a second gets `Busy` |
| `SaveWrite` | Save folder (saves root for import, plus the new save's folder while it is moved in) | Restore, live export, import, character recovery, save deletion, start-up recovery | One writer per save |
| `MaintenanceDispatch` | Backup folder | Maintenance runner | One dispatch at a time |
| `MaintenanceLane.<lane>` | Backup folder | That lane's process | One process per lane; doubles as the "is it running" probe |

[`OperationMutexSet`](../../src/PzTools.Process.Hosting/OperationMutexSet.cs) takes several of these in a fixed
order (scope, then path) so two operations cannot deadlock. Inside the app,
[`OperationCoordinator`](../../src/PzTools.App.Core/OperationCoordinator.cs) adds in-process gates per repository
and per save, so a second click is refused before a worker starts.

Below the mutexes, every write to a repository needs the [writer lock](glossary.md#writer-lock): `.writer.lock`
in the backup folder, opened with no sharing
([`RepositoryWriterLease`](../../src/PzTools.Backup.Storage/Repository/RepositoryWriterLease.cs)). Failing to open it
throws `RepositoryBusyException`. The heavy lanes that do not take `RepositoryAccess` retry the writer lock every
`writer_retry_delay_ms` (200 ms) instead.

### Leases inside the game

Two leases are kept in the game, not in Windows:

- The app run's lease: the WATCH stream sends `LEASE <app run>` once and renews it while open. Recordings the run
  started end when it lapses. See [game bridge](game-bridge.md#leases).
- The extension [control lease](glossary.md#control-lease), held by the state scheduler while it controls
  extensions. See [game extensions](game-extensions.md).

## How a backup and its maintenance are started

[`BackupScheduler.TickAsync`](../../src/PzTools.Scheduling/BackupScheduler.cs) runs every `wake_interval_ms`
(1000 ms) in the backup scheduler:

1. Ask the timing policy whether a backup is due ([game-aware timing](runtime-pause-backups.md)). If not, return.
2. On the first tick for a repository, mark its `backup-scheduler` workflows still `Running` as abandoned. Only
   one backup scheduler can run, so those belong to a dead one.
3. Allocate a run index and reserve a `backup-maintenance` workflow under it.
4. Signal every running heavy lane to yield (`MaintenanceLaneYield.<lane>` event).
5. Check the reservation and the play state again; a stop or an interval change may have arrived meanwhile.
6. Start the backup runner with that run index and wait for it.
7. After `Succeeded` or `NoChange`, start the maintenance runner with the same run index and wait for it. A
   maintenance failure is recorded but does not change the backup's outcome.
8. Complete the workflow and record `tick.completed`.

If the runner reports `Busy` (another job holds `RepositoryAccess`), no worker started and the workflow ends
`Busy`. The scheduler keeps the backup due and does not try again for 10 seconds, so an export holding the
repository does not cost a runner launch every second. A queued one-off backup is removed only once a worker has
started; until then each attempt only increments its attempt count
([`SchedulerDatabase.FinishBackupTickAsync`](../../src/PzTools.Scheduling/SchedulerDatabase.cs)). Missed ticks do
not pile up: after a run, the next due time is the first interval boundary after now
([`BackupScheduleTiming`](../../src/PzTools.Scheduling/BackupScheduleTiming.cs)), however many were missed. A worker
that could not be launched at all spends its slot (`ScheduleDisposition.Consume`); nothing was asked of the game,
so nothing is in doubt.

A runner started without `--run-index` (from the command line) allocates its own and reserves its own workflow.

<a id="maintenance-lanes"></a>
## Maintenance lanes

Maintenance dispatch ([`MaintenanceLanePipeline`](../../src/PzTools.Maintenance.Cli/MaintenanceLanePipeline.cs))
marks automatic revisions beyond retention as deleted under the writer lock, then starts the heavy lanes as
separate, detached processes and returns. Each lane takes its own `MaintenanceLane.<lane>` mutex, allocates its own
run index and reserves its own workflow.

| Lane | Started by | Locks | Work |
| --- | --- | --- | --- |
| `RevisionReclamation` | Dispatch, only when enough deleted revisions are waiting or the oldest is old enough | Lane mutex, writer lock | Compacts deleted revisions, then garbage-collects objects and packs |
| `ArtifactCleanup` | Dispatch, after an automatic backup that succeeded or had nothing to store | Lane mutex, writer lock | Deletes leftover temporary files and runs database housekeeping |
| `OrphanBackups` | State scheduler; the app once more as it closes | Lane mutex, `RepositoryAccess`, writer lock | Start-up-style recovery, removal of backups whose save folder is gone, database housekeeping, pack space reclamation |

The rules shared by all lanes:

- Dispatch does not start a lane while any game process exists, a lane checks again itself, and it is
  cancelled within a second when one appears
  ([`GameplayWorkGate`](../../src/PzTools.Process.Hosting/GameplayWorkGate.cs)). An error while listing processes
  counts as "a game may be running". Dispatch follows only a scheduled backup, which mostly runs while the game
  is open, so `RevisionReclamation` and `ArtifactCleanup` are usually skipped there. Their work is not lost:
  `OrphanBackups` runs the same housekeeping for every save once the game is gone (right after it exits, then
  about once a minute), compacting deleted revisions that are due and reclaiming pack space. Pausing the game
  does not count as gone: its process is still running.
- A lane already running makes dispatch report it `Busy` and go on with the others.
- A lane cancels itself when a backup scheduler sets its yield event.
- `RevisionReclamation` and `OrphanBackups` report a start and a heartbeat every 3 seconds only once they know
  they have work, so an idle check leaves no card. `ArtifactCleanup` reports an unplanned start and heartbeats
  from the beginning.

The state scheduler's [`OrphanCleanupDispatcher`](../../src/PzTools.Scheduling/OrphanCleanupDispatcher.cs) runs
whenever it has a repository, with or without automatic backups. It checks every `cleanup_interval_seconds`
(60 s), skips the launch while the repository's change counter and the list of save folders are unchanged since the
last launch, and launches anyway once an hour. When the game exits it launches at the next tick. The rules for what
counts as an orphan are in [repository housekeeping](repository-housekeeping.md).

## Child processes

[`ChildProcessHost`](../../src/PzTools.Process.Hosting/ChildProcessHost.cs) starts every supervised child:

- The child is put in its own Windows job object with kill-on-close and breakaway allowed. When the parent dies,
  Windows closes the job and the child and its descendants die with it.
- Standard output and error are read concurrently to the end. When the child exits, the job is terminated so a
  grandchild cannot hold the pipes open.
- On cancellation the parent sets the child's stop event `Local\PzTools-Stop-<pid>`
  ([`ProcessStopSignal`](../../src/PzTools.Process.Hosting/ProcessStopSignal.cs)), waits up to the grace period
  (2 seconds; `shutdown_grace_ms` for the app's children), then terminates the job. A child that does not listen is
  terminated at once.

The schedulers, the three runners, `PzTools.Backup.Cli`, `PzTools.Maintenance.Cli`, `PzTools.State.Collector.Cli`,
`PzTools.State.Reactor.Cli`, `PzTools.Zomboid.Archive.Cli`, `PzTools.Zomboid.Recovery.Cli` and
`PzTools.Profiler.Cli` listen for the stop event. A runner passes the request on to its worker with a shorter grace
(1.5 seconds, `ChildProcessHost.NestedShutdownGraceMs`), so that it can still report `Cancelled` and close its
reserved workflow before its own grace ends. A worker asked to stop reports `Cancelled` (exit code 2) and closes what
it opened as cancelled: the maintenance worker its stage, a lane its own workflow, the collector writes no batch and
the reactor rolls its transaction back.

[`DetachedProcessLauncher`](../../src/PzTools.Process.Hosting/DetachedProcessLauncher.cs) starts the maintenance
lanes with `CREATE_BREAKAWAY_FROM_JOB`, so they finish even when the app closes right after starting them. If the
surrounding job forbids breakaway (access denied), the lane starts inside the job instead.

## Starting, supervising and stopping

At start-up ([`App.OnLaunched`](../../src/PzTools.App/App.xaml.cs), then
[`AppHost.StartCoreAsync`](../../src/PzTools.App.Core/AppHost.cs)) the app:

1. Takes the `AppInstance` mutex, or signals the running instance and exits.
2. Opens `state.db` and `scheduler.db`, writes missing component configuration files, opens `logs.db` and the
   telemetry projection, and applies the saved settings to `scheduler.db`.
3. Runs [interrupted-operation recovery](#recovering-interrupted-operations) on the repository.
4. Starts the projection loops (every `projection_interval_ms`, 1000 ms) and restarts the periodic schedule: a new
   app session waits a full interval and never catches up an overdue backup.
5. Starts and supervises the two schedulers.

Supervision ([`AppHost.SuperviseAsync`](../../src/PzTools.App.Core/AppHost.cs)) restarts a scheduler that exits,
after `scheduler_restart_base_ms × 2^(attempt − 1)` (1, 2, 4 seconds). After `scheduler_restart_attempts` (3) the
scheduler shows as faulted and is retried every 60 seconds. A scheduler that ran for 60 seconds or more counts as
recovered and its attempt count starts again. Inside the state scheduler, a failure of the state stream or the state
feed ends the process so this supervisor restarts it; a failure of extension control is retried in place with a
growing delay of up to 60 seconds and does not stop observation
([`OptionalWorkSupervisor`](../../src/PzTools.Process.Hosting/OptionalWorkSupervisor.cs)).

On close ([`AppHost.DisposeCoreAsync`](../../src/PzTools.App.Core/AppHost.cs)) the app stops a running recording
(waiting up to 10 seconds), cancels the schedulers through their stop events, drains the projections, and starts one
detached `OrphanBackups` pass unless a game process exists. A restart to apply new configuration (`App.RestartForConfigurationAsync`) first
takes `RepositoryAccess` while it shuts the host down, so it is refused while a job holds the repository. The
running schedulers keep the backup folder they started with; `AppSettingsService.SaveAndApplyAsync` writes a new
one to `settings.toml` and it takes effect at the next start.

## How the schedulers share the game's state

The state scheduler is the only process that talks to the running game for state. It publishes what it reads on a
named pipe, `PzTools.Runtime.<24 hex digits of the hash of the scheduler.db path>`
([`RuntimeStateFeed`](../../src/PzTools.Process.Hosting/RuntimeStateFeed.cs)): four listeners, current user only,
read-only. The backup scheduler and the app follow it. A frame is sent on every change and at least once a second;
a follower that hears nothing for 2 seconds treats the game as unknown and reconnects.

<a id="game-state-decisions"></a>
### Choosing the backup target

The state scheduler's check ([`StateCheckPipeline`](../../src/PzTools.Scheduling/StateCheckPipeline.cs)) runs every
`interval_seconds` (3 s). It runs the collector and reactor inside the scheduler process, under `StateCollection`.
The first two checks after start, and two after Windows reports a game exit, are forced and run 150 ms apart.

Each save's activity comes from one of two sources:

| Game-aware timing | Activity read from | Result |
| --- | --- | --- |
| On | The game's state stream | `Active` for the save the game has loaded; `Inactive` at the menu, while unloading, when no game runs, or for other saves; `Unknown` while a world loads or when the stream is not fresh |
| Off | Opening `players.db` with no sharing | Sharing violation → `Active`; opened → `Inactive`; missing, access denied or other I/O error → `Unknown` |

The reactor ([`StateReactor`](../../src/PzTools.Zomboid.State/StateReactor.cs)) confirms a change after two
matching readings in a row and writes a command to the outbox in the same transaction:

| Confirmed change | Command |
| --- | --- |
| `Inactive` → `Active` | `ActivateTarget` |
| `Active` → `Inactive`, or the save is gone | `ClearTarget` |
| Several saves active | `SuspendAmbiguous` |

The relay ([`StateOutboxRelay`](../../src/PzTools.Scheduling/StateOutboxRelay.cs)) copies each command into
`scheduler.db` with its idempotency key and marks it delivered only after that commit, so a command relayed twice
is applied once. A check whose readings match the last check that changed nothing, with nothing changed in
`state.db` since, writes nothing and takes no run index.

With game-aware timing on, these commands do not move the backup target: `ApplyPendingCommandsAsync` ignores
them, and the relay sets the target from each committed game observation instead
(`SchedulerDatabase.ApplyRuntimeTransitionAsync`). They are kept only as the target of the wall-clock link
fallback ([when the game cannot be read](runtime-pause-backups.md#when-the-game-cannot-be-read)). Pause, sleep
and death decisions are in
[game-aware timing](runtime-pause-backups.md) and [live character death](runtime-character-death.md).

## Recovering interrupted operations

[`InterruptedOperationRecoveryService`](../../src/PzTools.Backup.Engine/InterruptedOperationRecoveryService.cs)
runs at app start (skipped if the repository is busy) and at the start of every `OrphanBackups` pass. It needs
`RepositoryAccess` and the writer lock, and `SaveWrite` for each save it touches.

- A workflow still `Running` becomes `Abandoned` only when every process recorded on it (PID and start time, for the
  workflow and its running stages) is confirmed gone. A process it cannot inspect counts as unverified and is
  reported, not abandoned.
- Leftover temporary files and unreferenced packs are removed.
- A save with a [restore journal](glossary.md#restore-journal) is settled from the journal (below). A pending
  [character recovery](character-recovery.md) edit is recovered.
- Restore staging without a journal is deleted only if the save exists and is not in use. A rollback folder
  without a journal, a damaged journal, or a reparse point anywhere above the saves folder is left alone and
  reported.

A problem with one save does not stop the others or the app. See
[restore safety](../reference/command-line.md#restore-safety) for what the player sees.

### Settling an interrupted restore

A restore ([`SafeRevisionRestoreService`](../../src/PzTools.Backup.Engine/SafeRevisionRestoreService.cs)) fills
`.<save>.pztools-staging-<id>` beside the save, moves the save to `.<save>.pztools-rollback-<id>`, then moves
staging into place. Before each step it rewrites the journal `.<save>.pztools-restore.json` with the phase it is
entering: `restoring`, `prepared`, `original-moved`, `installed`. A version 2 journal also records the Windows
directory identity of the staging folder (written at `prepared`) and, once recovery has moved the original back, of
the original. A failure before the save is moved discards only the staging folder and the journal.

Recovery trusts directory identities, not the phase label, because a rename can complete before the journal says
so:

| Found | Action |
| --- | --- |
| Save and rollback folder, the save's identity equals the staging identity, no staging folder | The restore finished: delete the rollback folder |
| Save and rollback folder, anything else (including a version 1 journal, which has no identity) | Keep the save, the rollback folder, the staging folder and the journal; report `restore-target-conflict` |
| Rollback folder, no save | Record the original's identity, move it back into place |
| Neither save nor rollback folder, phase past `restoring` | Keep everything; report `restore-target-conflict` |
| Save and staging folder, phase `original-moved` or `installed`, the save is not the recorded original | Keep everything; report `restore-target-conflict` |
| Otherwise | The save is settled: delete the journal, then any staging folder |

An access error or a reparse point also leaves everything in place. A restore whose rollback folder cannot be
deleted yet still counts as successful; the journal stays for the next recovery.
