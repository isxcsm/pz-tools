# Glossary

[Documentation index](../README.md)

Terms the code and the design pages use without explaining. A few words, such as *revision*, *generation*,
*slot* and *lease*, have more than one meaning; each meaning has its own entry. The [overview](overview.md) shows how the
parts connect.

## Backups and storage

### Repository

The backup folder (default `%USERPROFILE%\Zomboid\Backups`) and what PZ Tools keeps in it: `repository.db`, pack
files and temporary files. One repository holds the backups of every save. Code:
[`RepositoryDatabase`](../../src/PzTools.Backup.Storage/Repository/RepositoryDatabase.cs). See
[repository format](repository-format.md).

### Source

One save folder that is backed up, such as `Sandbox/My world`; a row in the `sources` table. Its key is the save's
path under `Saves`.

<a id="revision-backup"></a>
### Revision (backup)

One committed backup of one source: its files, their contents, and when and why it was made (`revisions` table). It
exists only once committed; an interrupted backup leaves none. Automatic revisions beyond
[retention](#retention) are marked deleted and their space is reclaimed later. Not to be confused with a
[settings revision](#settings-revision) or a [state revision](#state-revision).

### Object

The stored contents of one file version (`stored_objects`), identified by its content hash. Identical contents are
stored once, across revisions and across saves.

### Pack

A compressed file in the repository that holds many objects. Packs that are mostly unused are rewritten later. See
[pack format](pack-format.md).

### Catalog

The list of file versions that make up each revision (`paths` and `entry_versions` in `repository.db`).

### Tombstone

The record, in a revision, that a file present in earlier backups is gone. It is written only once the file's
absence is confirmed, so restoring that revision leaves the file out.

### Staging

A private copy made before anything is committed: a captured file before it reaches a pack, or the folder a
restore fills before it replaces the save. Nothing in staging is part of a backup or a save.

### Garbage collection (GC)

Removing objects and packs that no remaining revision uses. Objects still used by another save's backups stay.
Code: `RepositoryDatabase.CollectGarbageAsync`.

### USN journal

The NTFS change journal. PZ Tools reads it to find changed files without reading every file, and compares files
where it cannot. Code: [`PzTools.Backup.ChangeTracking.Windows`](../../src/PzTools.Backup.ChangeTracking.Windows/).
See [USN tracking](usn-journal.md).

### Stable capture

Copying a file that the game may still be writing: copy, check the copy against the file, and try again if the file
changed meanwhile. Code: [`StableFileCapturer`](../../src/PzTools.Backup.Engine/StableFileCapturer.cs). See
[stable capture](stable-capture.md).

### Retention

How many automatic backups are kept per save: `retained_revisions` in `settings.toml`, 20 by default. Manual
backups do not count. See [housekeeping](repository-housekeeping.md).

### Orphan backups

Backups whose save folder no longer exists. The `OrphanBackups` [maintenance lane](#maintenance-lane) removes them
once the folder is confirmed missing. Code:
[`OrphanBackupCleanupService`](../../src/PzTools.Backup.Engine/OrphanBackupCleanupService.cs).

### Restore journal

The file `.<save>.pztools-restore.json` beside a save, written before a restore swaps the restored copy in. After an
interruption it tells recovery which copy is in place. Code:
[`SafeRevisionRestoreService`](../../src/PzTools.Backup.Engine/SafeRevisionRestoreService.cs). See
[restore safety](../reference/command-line.md#restore-safety).

## Processes and jobs

### Component

A named producer with its own configuration and telemetry, such as `backup-worker` or `state-scheduler`. Its
editable settings are in `%LOCALAPPDATA%\PzTools\config\<component>\default.toml`. See
[advanced settings](../reference/advanced-settings.md).

<a id="scheduler-runner-worker"></a>
### Scheduler, runner, worker

The three process roles. A **scheduler** runs as long as the app and decides when work is due. A **runner** takes a
mutex and starts one worker. A **worker** does one job and exits. See
[process architecture](process-architecture.md).

### Run index

The number of one job attempt, unique across the installation and increasing. It ties together a job's workflow,
revision, telemetry and log entries. Allocated in `control.db` by
[`RunIndexAllocator`](../../src/PzTools.Control/RunIndexAllocator.cs), never below UTC Unix milliseconds × 65536;
numbers are never reused, including those of attempts that ended `Busy`. See
[process architecture](process-architecture.md#databases).

### Writer lock

`.writer.lock` in the repository, opened with no sharing by whoever writes to the repository. Code:
[`RepositoryWriterLease`](../../src/PzTools.Backup.Storage/Repository/RepositoryWriterLease.cs), so the code also
calls it the *writer lease*.

### Workflow

A job's record in `repository.db` (`workflow_runs`, `workflow_stages`), keyed by run index, with the PID and start
time of each process working on it. After a crash it tells recovery what was left unfinished.

### Maintenance lane

One kind of heavy maintenance that runs as its own detached process with its own mutex: `RevisionReclamation`,
`ArtifactCleanup` or `OrphanBackups`. Lanes run only while no game process exists and give way to a due backup. See
[process architecture](process-architecture.md#maintenance-lanes).

### Progress card

A card in the app for running or finished work: a backup, restore, export, recording and so on. Built from
telemetry by [`OperationCardStack`](../../src/PzTools.App.Core/OperationCardStack.cs). See the
[UI contract](ui-ux-contract.md).

### Projector

A loop in the app that turns a database or the game's state into a view for the screens: `StateProjector`,
`BackupProjector`, `SchedulerProjector` and others, run by
[`ProjectionHost`](../../src/PzTools.Projections/ProjectionHost.cs). A projector that fails shows as faulted, and
the actions that depend on its view are unavailable.

### Telemetry

The record each process keeps of its own work. Progress cards and the Logs page are built from it; nothing that
decides whether a backup exists reads it. See [telemetry](telemetry.md).

## Game state

<a id="active-save-target"></a>
### Active save, target

The save being played, as far as PZ Tools can tell. The backup scheduler calls it the *target*; automatic backups
are made for it.

### Activity

Whether a save is being played: `Active`, `Inactive` or `Unknown`. With game-aware timing on it comes from the
game's state stream, otherwise from whether the game has the save's `players.db` locked. Two matching readings in a
row confirm a change. Several active saves at once are *ambiguous*, and automatic backups wait. Code:
`GameActivityLane` in [`StateCollector.cs`](../../src/PzTools.Zomboid.State/StateCollector.cs).

<a id="collector-reactor-projection-outbox"></a>
### Collector, reactor, projection, outbox

The steps of a state check. The **collector** reads the saves and writes a batch of readings to `state.db`. The
**reactor** turns the batch into the current state (the **projection**) and, in the same transaction, into commands
for the backup scheduler in the **outbox**. A relay copies each command into `scheduler.db` once. Code:
[`StateCollector`](../../src/PzTools.Zomboid.State/StateCollector.cs),
[`StateReactor`](../../src/PzTools.Zomboid.State/StateReactor.cs),
[`StateOutboxRelay`](../../src/PzTools.Scheduling/StateOutboxRelay.cs).

### State revision

`state_revision` in `state.db`: a counter that goes up when the state the app shows changes. Readers compare it to
see whether anything is new.

<a id="observation-fresh-stale"></a>
### Observation, fresh, stale

A reading of the game's state (`RuntimeObservation`). *Fresh* means the game answered recently and its sample is
at most 2 seconds old. A stale or unknown reading never counts as active play. Code:
[`RuntimeSnapshotStore`](../../src/PzTools.Process.Hosting/RuntimeStateFeed.cs).

### Grace period, link fallback

The grace period is how long the game may stay unreadable (90 seconds) before periodic backups stop waiting for
it. After it, the *link fallback* runs them on the wall clock, backing up the files on disk if the game cannot
be asked to save. Code: `RuntimeScheduleController.DefaultLinkGrace`, `ApplyLinkFallback`. See
[game-aware timing](runtime-pause-backups.md#when-the-game-cannot-be-read).

<a id="generation-schedule"></a>
### Generation (schedule)

A counter in `scheduler.db`'s control row. It goes up when the backup target, the interval, the main switch,
the backup folder or game-aware timing changes, and at app start while automatic backups have a target. A new generation starts a full
interval, and admissions and checkpoints of an older one are dropped. The worker gets it as
`--runtime-generation`. Not a module's [generation](#generation-module).

### Schedule checkpoint

The backup scheduler's saved countdown (`runtime_schedule` in `scheduler.db`): remaining active time, hold,
slot, attempt id and the completion-unknown flag. A scheduler restart reloads it; a new generation, a target
switch or switching game-aware timing deletes it. See [game-aware timing](runtime-pause-backups.md#the-countdown).

### Hold

A reason the game-aware countdown does not run (`ScheduleHold`): automatic backups off, paused, asleep,
character dead, no world, game offline, several games, unsupported mode, unknown. The schedule line shows the hold.

### Slot (schedule)

One due periodic backup. An attempt either *uses* the slot (the next one is an interval later) or *keeps* it
(the same backup is tried again). Not the extension host's [slot](#slot).

### Guarded backup

A backup whose save request carries a [ticket](#ticket) (`SAVE_ACTIVE` or `PROBE_ACTIVE`): game-aware periodic
backups and death backups. The game checks the ticket every frame until it saves. See
[game bridge](game-bridge.md#the-save-request).

## Inside the game

### Game bridge

The Java code PZ Tools loads into the running game. It saves on request, streams the game's state, records
performance, shows in-game notes and hosts the extensions. See [game bridge](game-bridge.md).

### Attach

Java's mechanism for loading an agent into a running Java program. A helper process (the bundled `java.exe` running
`AttachMain`) uses it to load the bridge; no game file is changed.

### Bootstrap

The part of the bridge that stays loaded until the game exits (`pztools-game-bootstrap.jar`, class `AgentEntry`):
the control socket, the game-loop hook and the extension API classes. A PZ Tools update with a different bootstrap
API needs one game restart. Also called the *resident* part. See [module reload](module-reload.md).

### Payload

The replaceable part of the bridge (`pztools-game-bridge.jar`): save requests, the state stream, extension
control, the profiler, notes and leases. A newer payload replaces the old one while the game runs. See
[module reload](module-reload.md).

### WATCH

The connection kind for the game's state stream, held open by the state scheduler. The game sends its process,
world, pause, sleep, play time and the character's life and death. Code:
[`GameRuntimeClient`](../../src/PzTools.GameBridge/GameRuntimeClient.cs) and `RuntimeWatch.java`.

<a id="lease-app-run"></a>
### Lease (app run)

What one run of the app asks of the game lasts only while that run is heard from. Each app start makes a 32-hex-digit
id (`AppRun.Id`); the WATCH stream renews its lease. 120 seconds after the last renewal the game ends the recordings
the run started. See [game bridge](game-bridge.md#leases).

### Observer epoch

A random id the game makes for each WATCH subscription (`RuntimeObserver`). Readings and tickets carry it, so one
from an earlier connection or payload is refused.

### Admission

The checks that decide whether work may start. In the backup scheduler, a `BackupTickAdmission` is one due backup
that is checked again before the worker starts. In the game, a request is admitted only for the right process,
world and save in a state that allows it. A request that fails admission changes nothing.

### Ticket

`RuntimeSaveTicket`: the scheduler's permission for one game-aware backup to save the game. It names the process,
observer epoch, world and timing it was issued for, and the game checks them again just before saving.

### Save provider

The `SaveProvider` interface through which an extension module could carry out a backup's save in place of the
game's own save. None is shipped.

## Game extensions

<a id="extension-module"></a>
### Extension, module

An optional feature that runs inside the game; vehicle controls (`vehicle-drivetrain`) is the only one shipped.
Each ships as its own jar (the **module**) and is off by default. See [game extensions](game-extensions.md).

### Catalogue

`extensions\catalog.tsv` in `game-bridge` (source: `config/game-extensions/catalog.tsv`): one row per module, with
its version, Java namespace and entry class, jar, supported game versions and capability.

### Capability

The contract a module implements, such as `vehicle.drivetrain.v1`. It decides how the module is run.

### Provider

The class in a module that the host calls (`ContinuousProvider`): to validate and apply settings, on each game
frame, and to close.

<a id="extension-runtime-host"></a>
### Extension runtime, host

The replaceable library in the game (`pztools-extension-runtime.jar`, class `ModuleHost`) that loads modules, keeps
each in its own slot and calls them.

### Slot

The host's place for one module (`ContinuousRuntime`): its current generation, report and fault state. A fault
in one slot leaves the others working.

<a id="generation-module"></a>
### Generation (module)

One loaded instance of a module, with a random id. A changed jar or catalogue entry, a world change or a lost lease
ends it; the next `APPLY` makes a new one. Not the scheduler's [generation](#generation-schedule).

### Control lease

The state scheduler's claim to control the extensions in one game. Each command renews it; after 5 seconds without
one, or when the connection ends, every module turns itself off. Code: `ExtensionControl.java`.

### Settings revision

A counter in `%LOCALAPPDATA%\PzTools\extensions\settings.json` that goes up with every change to an extension
setting. The *requested* revision is what was saved, the *applied* revision is what the game runs; when they match,
the change has taken effect.

### Safe boundary

A moment when new settings or a new generation can take over without disturbing play. For vehicle controls: the
vehicle stopped, the accelerator released and cruise control off.

<a id="retire-revoke"></a>
### Retire, revoke

Two ways a generation stops. **Revoke** is immediate: no new calls, the game's own behaviour at once. **Retire**
revokes, waits up to 5 seconds for calls in progress, then deactivates and closes the module. See
[module reload](module-reload.md).

### Pass-through

A module's state after a fault (`FaultedPassThrough`): the game's own behaviour applies, and the module does nothing
until it is turned on again or its settings change.

### Probe mode

The vehicle module's `probe_only` setting: it reads the vehicle and computes what it would do, for diagnostics, but
changes nothing in the game.

### Restart required

The state of a slot or of the whole bridge that cannot go on without a game restart: a module that could not be
retired cleanly, or an incompatible bootstrap. Nothing new is loaded there until the game restarts. See
[module reload](module-reload.md#restart-required).
