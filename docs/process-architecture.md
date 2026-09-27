# Process architecture

[Documentation index](README.md) · [User guide](../README.md)

PzTools separates backup scheduling from game-state observation:

```text
BackupScheduler → BackupRunner → Backup worker
                → MaintenanceRunner → Maintenance dispatch
                                      ├─ RevisionReclamation child
                                      └─ ArtifactCleanup child

StateScheduler  → Collector → Reactor (in the scheduler process)
                → Scheduler outbox relay
StateRunner     → Collector worker → Reactor worker (manual/direct calls)
```

## Scheduling and isolation

BackupScheduler stores one dynamic target, cadence, enabled state, next due time,
and pending queue in `scheduler.db`. It passes a run index to BackupRunner.
After a successful or unchanged backup it waits for lightweight maintenance
dispatch; heavy maintenance children continue independently with their own run
indices and workflows.

Backup work takes priority. Heavy maintenance yields when a backup becomes due.
A busy repository preserves the due time for the next tick, and pending attempts
are consumed only when a backup worker actually starts. A maintenance failure
does not change a completed backup result.

BackupRunner and MaintenanceRunner coordinate through a mutex derived from the
normalized repository path. Maintenance dispatch and each heavy lane also have
their own mutexes, so an already-running lane does not block dispatch of other
lanes. Actual repository writes require `.writer.lock`. Direct runners allocate
from `control.db` before trying the mutex once; contention returns `Busy`
without launching a worker.

State collection uses a separate mutex based on `state.db`. Ordinary child
processes belong to a kill-on-close Windows Job Object, with stdout and stderr
drained concurrently. Heavy maintenance children are explicitly detached.

## Data ownership

| Database | Responsibility |
|---|---|
| `control.db` | Installation-wide atomic `run_index` allocation |
| `repository.db` | Sources, workflows/stages, revisions, catalog, object/pack locations |
| Repository `telemetry.db` | Detailed backup-engine events |
| Component `telemetry.db` | Events written only by that producer |
| `state.db` | Pending observations, current projections, transitions, outbox |
| `scheduler.db` | Target, cadence, pending work, idempotent command inbox |
| `logs.db` | App-facing projected logs |

Children reuse a supplied run index. Allocation failure does not fall back to a
repository-local or state-local counter. [Deployment layout](deployment-layout.md)
documents paths, and [configuration](configuration.md) documents per-process
configuration ownership.

The collector writes complete pending batches. The reactor transactionally applies
projections, transitions, and outbox messages. A meaningful externally visible
change increments `state_revision` once and stamps affected rows with that
revision. Readers compare revisions and read the projection in one read transaction.

## Game-state decisions

Save discovery searches markers under `Zomboid/Saves` without following reparse
points. File-lock activity probing opens `players.db` with read/write access and
exclusive sharing but writes no bytes: a Windows sharing violation means
`Active`, success means `Inactive`, and access or other I/O failures mean
`Unknown`. Character observation reads `isDead` through read-only SQLite.
Failed or unknown activity observations are stale. Without a confirmed fresh
active save, any stale/unknown observation makes overall activity unknown.

StateScheduler normally collects every three seconds. On a recognized Windows
game-process exit event it collects twice promptly to confirm inactivity; periodic
checks remain the fallback. Manual refresh and direct StateRunner calls use
separate workers. Runtime pause and activity observations have their own
[admission rules](runtime-pause-backups.md).

Two consecutive matching activity observations confirm a transition; unknown does
not advance the count. The resulting commands are:

| Confirmed condition | Scheduler action |
|---|---|
| Inactive → active | `ActivateTarget` |
| Active → inactive, or save disappears | `ClearTarget` |
| Multiple active saves | `SuspendAmbiguous` until a single target is confirmed |
| Character death with death backups enabled and current play active | `RunOnceNow` |

The outbox relay preserves idempotency keys and acknowledges only after inbox
commit. Character alive/dead changes also remain separate recorded transitions.

Activation schedules the first periodic backup one interval later. Interval
changes start a new interval without reactivating suspended or ambiguous state.
Pending state commands are applied before configuration changes. Game exit does
not schedule a final backup, and legacy final reservations are not executed.

Before launching, the scheduler rechecks the reservation and play state. Automatic
workers also check before and after game-save preparation/countdown. Stopped or
uncertain play skips capture; game exit alone does not interrupt capture already
in progress. Manual backups can run while the game is closed. The UI countdown
requires an enabled schedule and a fresh single active save.

## Retention and maintenance

The app defaults to retaining 20 active automatic backups; directly invoked
maintenance without an override defaults to 100. Manual and unknown-origin
backups are excluded from count-based retention. Excess automatic revisions become
`Deleted` immediately, while physical reclamation waits for an eligible batch
or age threshold. Automatic pack recompression is disabled. See
[repository housekeeping](repository-housekeeping.md) for these limits and the
separate cleanup lanes.

StateScheduler also dispatches `OrphanBackups` about once a minute when given a
repository and saves root, even with automatic backups disabled. Heavy cleanup is
deferred while the game process is running, in its menus, or of uncertain status.
A lane that detects game startup yields at its cancellation boundary. Collection
does not wait for cleanup.

Orphan cleanup requires the stored source key/path to match the configured
`Saves/<mode>/<save>` location and successful parent enumeration proving the
folder is missing. Inaccessible roots, reparse points, restore journals, and active
workflows defer cleanup. An existing folder is retained even without `players.db`.

Confirmed orphan cleanup permanently removes both manual and automatic backups.
GC preserves objects shared by other saves. It retains an empty hidden baseline
at the latest revision number and clears the USN checkpoint, preventing revision
and cache collisions if a same-named save is recreated.

## Interrupted operations

Before starting schedulers, the app runs `InterruptedOperationRecoveryService`;
the orphan lane retries it later. Recovery requires the repository-access lock
and writer lease, plus SaveWrite for save-specific work.

Workflows record owner PID and process start time. Running work becomes
`Abandoned` only when the parent and active stage processes are confirmed dead.
Missing ownership information, access uncertainty, and PID reuse do not justify
guessing. Uncertain artifacts remain preserved and reported.

Recovery reclaims unfinished staging/quarantine files and unreferenced packs,
and reconciles valid restore journals. Journal-less restore or character-recovery
staging is removed only when the original exists and is not in use. Lone rollback
directories, damaged journals, and reparse points remain untouched. One save's
recovery failure does not block others or app startup. See [restore safety](cli.md#restore-safety).

`state.db` and `scheduler.db` reject newer unsupported schemas without changes;
older schemas may migrate forward. Repository format compatibility is stricter,
as described in [repository format](repository-format.md).
