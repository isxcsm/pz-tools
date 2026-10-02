# Glossary

[Documentation index](README.md) · [User guide](../README.md) · [Overview](overview.md)

The words the other pages use without explaining. Some ordinary words have a narrow
meaning here; a few, such as *revision* and *generation*, have more than one, so check
which one a page means. For how the pieces connect, read the [overview](overview.md).

## Backups and storage

### Repository

The backup folder you choose, with everything PZ Tools stores in it: `repository.db`,
the pack files and temporary staging files. One repository can hold backups of many
saves. See [repository format](repository-format.md).

### Source

One save folder that is backed up, such as `Saves/Sandbox/My world`. The repository
keeps a record per source.

### Revision (backup)

One backup of one source: which files it contains, their contents, and when and why
it was made (manual, automatic or death). A revision exists only once it is committed;
an interrupted backup leaves none. Automatic revisions beyond the retention limit are
marked deleted first and their space is reclaimed later.
For the other meanings see [settings revision](#settings-revision) and
[state revision](#state-revision).

### Object

The stored contents of one file version. Identical contents are stored once, even when
they appear in several revisions or several saves.

### Pack

A compressed file in the repository that holds many objects. Packs whose objects are
mostly no longer needed are rewritten later to give space back. See [pack format](pack-format.md).

### Catalog

The part of `repository.db` that lists which file versions belong to each revision.

### Tombstone

The record, in a revision, that a file which was in earlier backups no longer exists.
It is written only once the file's absence is confirmed, so restoring that revision
leaves the file out.

### Staging

A private copy made before anything is committed: the in-memory or temporary copy of a
file during capture, and the folder a restore fills before it is put in place of the
save. Nothing in staging is part of a backup or a save until the final step.

### Garbage collection (GC)

The cleanup step that removes stored objects and packs that no remaining revision
needs. Objects still used by another save's backups are kept.

### USN journal

A Windows NTFS feature that records which files changed. PZ Tools uses it to find
changed files without reading every file; where it is not available, files are
compared instead. Reading it is the reason the app asks for administrator permission.
See [USN tracking](usn-journal.md).

### Stable capture

How a file is copied while the game may still be writing it: copy, check the copy
against the file, and try again if the file changed meanwhile. See [stable capture](stable-capture.md).

### Retention

How many automatic backups are kept per save (20 by default). Manual backups do not
count towards it.

### Orphan backups

Backups whose save folder no longer exists. They are removed by a cleanup pass, but
only after the folder is confirmed missing. See [housekeeping](repository-housekeeping.md).

### Restore journal

A small file written before a restore replaces a save. The old save is moved aside and
the restored copy is put in its place in one step. If the restore is interrupted, the
journal lets the next start tell which of the two is in place and clean up the other.
See [restore safety](cli.md#restore-safety).

## Processes and jobs

### Component

One named background program with its own settings folder, for example
`backup-worker` or `state-scheduler`. See [configuration](configuration.md).

### Scheduler, runner, worker

Three roles. A **scheduler** runs for as long as the app and decides *when* work is
due. A **runner** starts one job safely: it takes a run index and the locks, then
launches the worker. A **worker** does the job and exits. See [process architecture](process-architecture.md).

### Run index

A number handed out once per job attempt, increasing across the whole installation.
It ties together everything that job wrote: its revision, its log entries, its
diagnostics. Numbers of failed or skipped attempts are not reused.

### Writer lock

`.writer.lock` in the repository. Only the process holding it may change the
repository, so two jobs never write at the same time. Some pages call it the
*writer lease*.

### Workflow

The record a job keeps in `repository.db` while it runs, stage by stage. After a crash
it tells the next start what was left unfinished and what can be cleaned up.

### Maintenance lane

One kind of heavy maintenance, run as its own process with its own lock:
reclaiming deleted revisions, cleaning up leftover files, or removing backups of deleted
saves. A lane that is running does not stop the others from starting, and every lane
gives way to a backup. See [housekeeping](repository-housekeeping.md).

### Progress card

The cards in the app that show running and finished work: backups, restores, exports,
recordings and so on. They are drawn from telemetry. See the [UI contract](ui-ux-contract.md).

### Projector

The part of the app that turns stored data (game state, backups, the schedule) into
the views the screens show. A projector that fails is reported on its own card, and
actions that depend on it are blocked.

### Telemetry

Diagnostic events each process writes to its own database. The app's progress cards,
logs and timings are read from them. Telemetry never decides whether a backup
succeeded. See [telemetry](telemetry.md).

## Game state

### Active save, target

The save being played right now, as far as PZ Tools can tell. Automatic backups are
made for this save; the scheduler calls it the *target*.

### Activity

Whether a save is in use, found by checking whether the game has its files locked:
*Active*, *Inactive* or *Unknown*. Two matching checks in a row are needed before
the app acts on a change. Several active saves at once are *ambiguous*, and automatic
backups wait.

### Collector, reactor, projection, outbox

The steps that turn file checks into scheduling decisions. The **collector** records
what it saw. The **reactor** turns that into the current picture (the **projection**)
and into commands for the backup scheduler, which it leaves in the **outbox**. A
command delivered twice is still applied only once.

### State revision

A counter in `state.db` that goes up whenever the current picture of the game changes
in a way the app should show. Readers compare it to know whether anything is new.

### Observation, fresh, stale

A reading of the game's state, from files or from the game itself. *Fresh* means
recent enough to act on. A *stale* or unknown reading never counts as active play.

### Grace period

How long the game may stay unreadable (about 90 seconds) before periodic backups stop
waiting for it and follow the wall clock instead. See
[game-aware timing](runtime-pause-backups.md#when-the-game-cannot-be-read).

## Inside the game

### Game bridge

The Java component PZ Tools loads into the running game. It saves on request,
streams the game's state and hosts extensions. See [game bridge](game-bridge.md).

### Attach

Java's standard way to load code into a running Java program. PZ Tools uses it to
load the game bridge; no game file is changed.

### Bootstrap

The part of the game bridge that stays loaded until the game exits: it accepts
connections and hands commands to the other parts. If PZ Tools ships an incompatible
bootstrap, the game has to be restarted once to use it. Pages also call it the
*resident* part.

### Payload

The replaceable part of the game bridge: saving, the state stream and extension
control. A newer payload replaces the old one while the game runs, at an idle moment.
See [component updates](module-reload.md).

### WATCH

The state stream from the game to the state scheduler: process, world, pause, sleep,
active play time, and the character's life and death. `WATCH` is the connection
kind the app asks for when it opens the stream. The current message format is in
the [compatibility table](game-bridge.md#compatibility-and-lifecycle).

### Observer epoch

An identifier for one WATCH connection. It changes when the stream is reconnected or
the payload is replaced, so an old reading can never be mistaken for a new one.

### Admission

The checks that decide whether a request may run in the game at all: the right
process, world and save, the game in a state that allows it, the request not out of
date. A request that fails admission changes nothing.

### Save provider

The code in the game that carries out a backup's save request. The standard provider
calls the game's own save. The design allows an extension to offer another provider,
but none is shipped; the game keeps one slot for it, separate from the extensions'
control lease.

### Ticket

Permission the scheduler gives one periodic backup to save the game. It names the
process, world and timing it was issued for; the game checks all of them again just
before saving.

## Game extensions

### Extension, module

An optional feature that runs inside the game; vehicle driving improvements is currently
the only one. Each ships as its own archive (the **module**) and is off by default. See
[game extensions](game-extensions.md).

### Catalogue

`config/game-extensions/catalog.tsv`: one row per extension, with its archive,
supported game versions and capability.

### Capability

The named contract a module implements, such as `vehicle.drivetrain.v1`. It decides how the module is started. *Continuous* modules run
for the whole play session; *per-save* modules would act only around a save and none
is currently shipped.

### Provider

The class in a module that the host calls: to apply settings, on each game frame, and
to shut down.

### Extension runtime, host

The replaceable Java library inside the game that loads modules, keeps each in its
own slot and calls them. It can be replaced while the game runs.

### Slot

The host's place for one module: its loaded archive, current settings and fault state.
One module faulting clears only its own slot.

### Generation (module)

One loaded copy of a module. Updating the module's archive or definition loads a new
generation and retires the old one. The scheduler also has *timing generations*,
which identify one countdown policy; they are unrelated.

### Control lease

The state scheduler's claim to control the extensions in one game. It lasts a few
seconds and is renewed while PZ Tools is running. If it is not renewed, for example
because the app closed, every module turns itself off.

### Settings revision

A counter in `%LOCALAPPDATA%\PzTools\extensions\settings.json` that goes up with every
change to any extension setting. The *requested* revision is what you saved; the
*applied* revision is what the game is running. When they match, the change has taken
effect.

### Safe boundary

A moment when a change can be applied without disturbing play. For vehicle controls:
all vehicles stopped, accelerator released and cruise control off.

### Retire, revoke

Two ways a module stops. **Retire** is orderly: no new calls, wait for calls in
progress, release what it holds. **Revoke** is immediate, after a fault or a lost
lease; the game goes back to its own behaviour straight away.

### Pass-through

What happens after a module faults: the game's original behaviour is used in its
place, and the module does nothing until you turn it on again or change its settings.
The status for this is `FaultedPassThrough`.

### Probe mode

A developer setting of the vehicle extension (`probe_only`): it reads the vehicle and
computes what it would do, for diagnostics, but changes nothing in the game.

### Restart required

The state reported when a module or payload could not be retired cleanly. Nothing new
is loaded until the game is restarted, because the old code might still be running.
