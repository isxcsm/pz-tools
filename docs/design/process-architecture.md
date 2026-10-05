# Process architecture

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

PZ Tools does its work in small background programs rather than inside the app window.
This page is for people reading or changing that code. It explains which programs
exist, how a backup or a cleanup gets started safely, how the app decides which save
is being played, which database each program owns, and how unfinished work is cleaned
up after a crash. The [overview](overview.md) gives the big picture; read it first.

## The processes

Backup scheduling and watching the game are two separate chains:

```text
BackupScheduler → BackupRunner → Backup worker
                → MaintenanceRunner → Maintenance dispatch
                                      ├─ RevisionReclamation child
                                      └─ ArtifactCleanup child

StateScheduler  → Collector → Reactor (in the scheduler process)
                → Scheduler outbox relay
                → OrphanBackups lane (maintenance worker, detached)
StateRunner     → Collector worker → Reactor worker (manual/direct calls)

App             → one on-demand worker per operation: restore, archive import/export,
                  character recovery, performance recording
```

Each chain follows the [scheduler, runner, worker](glossary.md#scheduler-runner-worker)
pattern: the scheduler decides when, the runner takes a
[run index](glossary.md#run-index) and the locks, and the worker does the job.

| Process | Role |
| --- | --- |
| BackupScheduler | Keeps the backup target, cadence and queue; decides when a backup is due |
| BackupRunner | Starts one backup worker safely |
| MaintenanceRunner | Starts maintenance dispatch, which starts the heavy cleanup children |
| RevisionReclamation, ArtifactCleanup | Heavy maintenance [lanes](repository-housekeeping.md), each its own process |
| StateScheduler | Collects the game's state every few seconds and runs the collector and reactor in its own process; keeps enabled [game extensions](game-extensions.md) in step with the running game and starts the `OrphanBackups` lane ([below](#backups-of-deleted-saves)) |
| Scheduler outbox relay | Delivers the reactor's commands to the backup scheduler |
| StateRunner | Runs the collector and reactor as separate workers for manual refreshes and direct calls |
| On-demand workers | Started by the app for one operation each: restore (`PzTools.Backup.Cli`), archive import and export (`PzTools.Zomboid.Archive.Cli`), [character recovery](character-recovery.md) (`PzTools.Zomboid.Recovery.Cli`) and [performance recording](profiler.md) (`PzTools.Profiler.Cli`). Their telemetry lives under `operations\` in the app data folder |

<a id="game-state-decisions"></a>
## How automatic backups follow the game

Automatic backups are made for the [active save](glossary.md#active-save-target), the
one being played. This section describes how that save is found and how its changes
turn into scheduler commands. Pause, sleep and other readings from inside the game have
their own [admission rules](runtime-pause-backups.md).

### Finding the active save

Save discovery searches for save markers under `Zomboid/Saves`. It does not follow
reparse points.

[Activity](glossary.md#activity) is found by opening the save's `players.db` with
read/write access and exclusive sharing. Nothing is written to it. The result decides
the reading:

| Result of opening `players.db` | Activity |
| --- | --- |
| Windows sharing violation (the game has it open) | `Active` |
| Success | `Inactive` |
| Access failure or any other I/O failure | `Unknown` |

Whether the character is alive is read from `isDead` through read-only SQLite.

StateScheduler normally collects every three seconds. When Windows reports that a
recognised game process has exited, it collects twice promptly to confirm the save
is inactive; the periodic checks remain the fallback. A manual refresh and a direct
StateRunner call use separate workers.

A check whose readings match those of a check that changed nothing, with nothing else
having changed the state since, writes nothing: no batch, no run number and no
telemetry. While the app sits in the tray, state checks therefore leave the disk alone.
The due time is kept in memory; the first checks after a start are forced anyway, and a
clock set back does not pause the checks.

### From readings to scheduler commands

A failed or unknown activity reading is [stale](glossary.md#observation-fresh-stale).
Unless there is a confirmed, fresh active save, any stale or unknown reading makes the
overall activity unknown.

A change is confirmed by two matching file-activity readings in a row. An unknown
reading does not count towards the two. Confirmed changes produce these commands:

| Confirmed condition | Scheduler action |
| --- | --- |
| Inactive → active | `ActivateTarget` |
| Active → inactive, or the save disappears | `ClearTarget` |
| Several active saves | `SuspendAmbiguous` until a single target is confirmed |

The outbox relay keeps each command's idempotency key and acknowledges a command only
after the backup scheduler's inbox has committed it, so a command delivered twice is
applied once. When the game's own state stream ([WATCH](glossary.md#watch)) controls
scheduling, these file-based commands cannot replace its target.

### Saves being restored or missing

A save is skipped during a restore only while its
[restore journal](glossary.md#restore-journal) exists **and** a worker holds that
save's write lock. A journal left behind by a failed or crashed restore does not hide
an existing save from observation or automatic backups. If the save folder itself is
missing, discovery is treated as incomplete, not as a deletion.

### When the periodic backup runs

- Activation schedules the first periodic backup one interval later.
- Changing the interval starts a new interval. It does not reactivate a suspended or
  ambiguous state.
- Pending state commands are applied before configuration changes.
- Before launching, the scheduler checks the reservation and the play state again.
  Automatic workers also check before and after preparing the game save and its
  countdown. If play has stopped or is uncertain, the capture is skipped.
- The game exiting on its own does not interrupt a capture already in progress.
- Manual backups can run while the game is closed.
- The countdown in the app is shown only when the schedule is enabled and there is a
  fresh, single active save.

### Death backups

A death backup needs a fresh, live death identity from the observer running in the
game (the JVM observer, through [WATCH](glossary.md#watch)). While both automatic
backups and death backups are enabled, at most one `RunOnceNow` is queued per observed
death. Before saving, the game checks the process, world, character and death identity
again. Pause and the periodic countdown do not hold this work back. See
[live character death](runtime-character-death.md).

A change of `isDead` read from the save file is recorded only as a metadata
transition; it never requests a death backup. Death commands derived from the database
by older versions are discarded.

## Starting a backup safely

BackupScheduler stores its state in `scheduler.db`: one dynamic target, the cadence,
whether it is enabled, the next due time and the pending queue. It hands a run index
to BackupRunner.

- **Backups come first.** Heavy maintenance yields when a backup becomes due.
- **A busy repository keeps its place.** If the repository is busy, the due time is
  kept and the scheduler tries again about 10 seconds later. A pending attempt is used
  up only when a backup worker actually starts.
- **Maintenance follows a backup.** After a successful or unchanged backup the
  scheduler waits for the lightweight maintenance dispatch. The heavy maintenance
  children then continue on their own, with their own run indices and
  [workflows](glossary.md#workflow).

## Retention and maintenance

The app keeps 20 active automatic backups by default. Maintenance run directly,
without an override, keeps 100. Manual backups and backups of unknown origin do not
count towards [retention](glossary.md#retention).

Automatic revisions beyond the limit are marked `Deleted` straight away. Their space is
reclaimed later, when an eligible batch has built up or an age threshold is reached.
The periodic worker rewrites [pack](glossary.md#pack) files that are mostly unused. See
[repository housekeeping](repository-housekeeping.md) for these limits and the
separate cleanup lanes.

### Backups of deleted saves

StateScheduler dispatches the `OrphanBackups` lane when it has been given a repository
and a saves root, even with automatic backups turned off. It checks about once a minute,
but skips the pass while neither the repository's backups nor the list of save folders
has changed; it rechecks anyway once an hour. It also dispatches the lane immediately
when the game exits, and the app dispatches one more pass as it closes.

- Heavy cleanup waits while the game process is running, while the game is in its
  menus, and while its status is uncertain.
- A lane that notices the game starting yields at its next cancellation point.
- State collection does not wait for cleanup.

A backup set counts as an [orphan](glossary.md#orphan-backups) only when both hold:

1. The stored source key and path match the configured `Saves/<mode>/<save>` location.
2. Listing the parent folder succeeds and shows the save folder is missing.

Cleanup is put off when the root is inaccessible, when a reparse point is involved,
when a restore journal exists, or when a workflow is active. A save folder that still
exists is kept, even without `players.db`.

Confirmed orphan cleanup removes **both manual and automatic** backups of that save,
permanently. Garbage collection keeps [objects](glossary.md#object) that other saves
share. It leaves an empty, hidden baseline at the latest revision number and clears the
[USN](glossary.md#usn-journal) checkpoint, so that a new save with the same name cannot
collide with old revision numbers or cached state.

## Limits

- **No final backup on exit.** The game exiting does not schedule a last backup, and
  final-backup reservations left by older versions are not run.
- **Death backups come only from the live game.** A dead character found in the save
  file does not trigger one.
- **No fallback run index.** If a run index cannot be allocated, the run fails. There
  is no fallback to a counter local to the repository or to `state.db`.
- **Maintenance cannot undo a backup.** A maintenance failure does not change the
  result of a completed backup.
- **Uncertain leftovers are kept.** Crash recovery does not guess: files it cannot
  prove are unfinished stay where they are and are reported (see below).
- **Newer databases are refused.** `state.db` and `scheduler.db` reject a newer,
  unsupported schema without changing it; older schemas may be migrated forward.
  Backup folders follow stricter rules, described in
  [repository format](repository-format.md).

## How it works inside

### Locks and mutexes

| Lock | Held by | Purpose |
| --- | --- | --- |
| Mutex from the normalised repository path | BackupRunner and MaintenanceRunner | Only one of them works on a repository at a time |
| Maintenance dispatch mutex, and one mutex per heavy lane | Dispatch and each lane | A lane that is already running does not block dispatching the others |
| [`.writer.lock`](glossary.md#writer-lock) in the repository | Whoever writes | Required for every actual repository write |
| Mutex based on `state.db` | State collection | Keeps state collections from overlapping |

A runner called directly allocates its run index from `control.db` first, then tries
the mutex once. If the mutex is taken it returns `Busy` without launching a worker.

### Child processes

Ordinary child processes belong to a Windows Job Object that kills them when it is
closed. Their stdout and stderr are drained concurrently. Heavy maintenance children
are explicitly detached, so they are not part of that job.

Cancelling a child first asks it to stop through a named event
(`Local\PzTools-Stop-<pid>`). The CLIs listen for it and stop at their next
cancellation point, so a run can record its own cancellation. A child that does not
stop within about 2 seconds, or does not listen, is ended.

### Which database holds what

| Database | Responsibility |
| --- | --- |
| `control.db` | Installation-wide atomic `run_index` allocation |
| `repository.db` | Sources, workflows and stages, revisions, catalog, object and pack locations |
| Repository `telemetry.db` | Detailed backup-engine events |
| Component `telemetry.db` | Events written only by that producer |
| `state.db` | Pending observations, current projections, transitions, outbox |
| `scheduler.db` | Target, cadence, pending work, idempotent command inbox |
| `logs.db` | Logs projected for the app |

Child processes reuse the run index they are given.
[Deployment layout](../reference/files-and-folders.md) lists where each file lives,
[configuration](../reference/settings.md) which settings each process owns, and
[telemetry](telemetry.md) what the telemetry databases hold.

### The state pipeline

The [collector](glossary.md#collector-reactor-projection-outbox) writes complete batches
of pending readings. The reactor applies projections, transitions and outbox messages
in one transaction. A meaningful change that others can see increments
[`state_revision`](glossary.md#state-revision) once and stamps the affected rows with
that revision. Readers compare revisions and read the projection in a single read
transaction.

### Recovering interrupted operations

Before starting the schedulers, the app runs `InterruptedOperationRecoveryService`;
the orphan lane retries it later. Recovery needs the repository-access lock and the
writer lease, plus the SaveWrite lock for work on a particular save.

Workflows record the owner's PID and process start time. Running work becomes
`Abandoned` only when the parent process and the active stage's processes are
confirmed dead. Missing ownership information, uncertain access and PID reuse are not
treated as proof.

What recovery does:

- Reclaims unfinished staging and quarantine files and unreferenced packs.
- Reconciles valid restore journals.
- Removes restore or character-recovery staging that has no journal, but only when the
  original exists and is not in use.

What it leaves untouched: lone rollback folders, damaged journals and reparse points.
Uncertain artifacts are preserved and reported. A recovery failure for one save does
not block the others or app startup. See [restore safety](../reference/command-line.md#restore-safety).
