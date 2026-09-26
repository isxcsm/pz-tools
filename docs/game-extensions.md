# Game extensions and Seamless Saving

[Documentation index](README.md) · [Save bridge](save-bridge.md) · [Live character state](runtime-character-death.md)

## Current scope

The experimental Seamless Saving module is **0.6.0**. It uses save protocol **6**,
bootstrap API **6**, and the shared runtime observation stream. Install matching
app/worker/JARs and completely restart the game after changing bootstrap or module
code. No backup-repository schema reset is needed.

This is a low-interruption save pipeline, **not a fully nonblocking or atomic world
snapshot**. It preserves the original game-thread `GameWindow.save(true)` and its
OnSave, chunk serialization, player/vehicle, virtual vehicle, animal and native
subsystem work. The optional module changes selected waiting and I/O boundaries;
it does not replace full saving with a player-only or occupied-vehicle-only save.
Real-game drag behavior, frame-time improvement and restored worlds still require
isolated gameplay validation. The card name is not a zero-stall guarantee.

This branch incorporates dev `cc5f591`, retaining the icon/support UI, inline log
filters, recovery guidance and pause-aware scheduling. Integration is into the
feature branch only, not a merge of this feature into dev or main.

## One request pipeline

1. **Select and validate.** Read extension preferences, check its declared game
   version range, resolve the optional provider and validate the actual game code.
   Unsupported modules use standard saving before mutation starts. The pre-backup
   game-save setting retains precedence over extension preferences.
2. **Wait before capture, without saving.** The provider's side-effect-free
   `readyToCapture` probe yields to the next game tick while known chunk/native
   work is busy or the database worker is unavailable. No sleep/join, partial
   serialization or source write happens in this new phase. Countdown cancellation,
   pause/death tickets and permission withdrawal can still cancel it. World/cell
   identity is pinned during this wait and revalidated before admission.
3. **Capture once on the correct thread.** Reserve the completion worker BEFORE
   capture can mutate the game. Keep the original save and serializers, including
   recovery metadata. Suppress only this module request's forced thumbnail render;
   the existing thumbnail remains. Ordinary saves still render their thumbnail.
4. **Own and order writes.** Existing chunk-file writes use copied immutable bytes
   and an already opened destination channel. The single writer preserves order.
   New files, unsupported buffers and budget exhaustion use original ordered I/O.
   Limits remain 64 MiB of owned copies and 128 pending/executing file operations.
5. **Serve dependent game reads.** A locked `SafeRead` may copy the latest pending
   bytes into its own buffer instead of waiting for disk. It never receives the
   retained array. The original read lock and sanity/finally cleanup still run.
   A replaced path or unavailable identity uses the ordered disk-read path instead.
6. **Await all required completions.** The original native worker must finish its
   collision/population save; post-capture player/vehicle drains must acknowledge;
   owned chunk channels, read copies and failure cleanup must be released. Only
   then is a typed success receipt visible and the existing backup preparation
   callback allowed to return. Native, file and DB completions cannot substitute
   for one another.
7. **Back up and report.** The unchanged engine captures the live source directory.
   The shared runtime reports the actual provider, fallback/failure and preparation/
   total time to the extension card. A requested toggle is not proof of application.

The readiness probe is advisory, not a new lock or an atomic idle reservation.
A worker starting immediately after it is handled by the ORIGINAL game's checks;
those checks were not removed. Waiting remains bounded by the existing request
lifetime, and expiration before capture is not a successful save.

### Read-through and Windows file identity

`BasicFileAttributes.fileKey()` is null in the inspected Windows JDK. Timestamps or
sizes are NOT used as substitute identities. The version-bound module obtains the
JDK's file key from an OPEN `FileChannel` descriptor and compares it to an opened
read channel for the current path. Thus a pending write for a renamed file is not
returned as data for a replacement at the old path.

`PinnedFileIdentity` contains the JDK-25 implementation dependency. Instrumentation
opens only `java.base/sun.nio.ch` to this trusted module's module identity, not to
all game code. No new DLL, process, hard link or file sidecar is added. When this
access/layout is unavailable, the read-through optimization is disabled and the
ordered disk read remains. The standalone harness grants equivalent test-process
access explicitly; that launch flag is not added to the user's game command line.

A memory read is NOT a disk-commit acknowledgement. The backup cannot proceed on
the basis of a successful cache read; it still awaits every required completion.
Pending bytes remain within the same accounting budget through concurrent copying.

### Failure, cancellation and world changes

Completion execution is submitted before capture starts. Submission failure therefore
cannot strand a partially mutated save. Once capture begins, snapshot validation
failure and shutdown also finish via the already-owned completion worker. Potentially
blocking `PreparedSave.close()` never runs on the game thread in that path.

Database drain scopes track in-flight calls as well as post-capture acknowledgements.
Losing the world is an error, not evidence that the pinned database thread stopped
writing. Cleanup waits for the acknowledged work or that exact worker's termination;
a dead worker without acknowledgements is failure, not success. A still-running,
unacknowledged worker retains ownership and the client reports completion unknown.
There is no automatic replay of standard saving after an extension starts.

The native-wait boundary retains the original worker, inputs and two native save
calls. Later ordinary saves and shutdown may wait for a dependency on earlier work.
See [native wait analysis](seamless-native-wait.md) for the exact B42.20 boundary.

## Project and state ownership

| Layer | Responsibility |
| --- | --- |
| GameExtensions (`net10.0`) | Extension catalogue, numeric version policy, preference revisions; no WinUI/game dependency |
| App.Core / App | Projection, card, toggle and modal; no game persistence code |
| Zomboid.Backup / SaveBridge | Existing preparation policy, authenticated transport and typed result |
| Stable Java API / runtime | Provider readiness/capture/completion and bounded ownership |
| SeamlessSave/b4220 | Game/JDK-sensitive reflection, transformation, file and native/DB completion policy |
| Backup.Engine | Source preparation followed by normal capture/revision creation; no mod-specific branch |

One bootstrap and GameWindow dispatch hook serve independent WATCH and exclusive
SAVE sessions. Pause, game version, live character state and save execution feedback
reuse the same observation stream. There is no extra per-card Attach/collector/DB.
Saved `players.db` CharacterState is still separate from JVM Alive/Dead facts and
observed death episodes. Periodic pause guards, exact-character death guards and
master automatic-backup settings continue to apply to both save providers.

## Version and activation policy

`config/game-extensions/catalog.tsv` is the shared UI/JVM deployment catalogue.

| Scope | Example | Meaning |
| --- | --- | --- |
| All | - / - | No declared restriction; current Seamless Saving policy |
| Major | 42 / - | Major 42 and later, available to a future vehicle extension |
| Major | 42 / 42 | Only 42.x |
| Minor | 42.20 / 42.25 | Inclusive minor range, including patch versions |

Numeric components are compared, not decimal values or lexicographic strings.
Restricted unknown/mismatched versions disable normal activation without erasing
preferences. The settings modal permits an explicit warned version override.
Override affects the declaration ONLY, not authentication, code shape, thread/world
identity, save guards or completion checks. All is not an assertion that arbitrary
game binaries are supported: this adapter still validates the inspected 42.20 code.
Module code updates require restart; toggles do not reload JARs or retransform classes.

## Validation and remaining work

Focused validation uses the existing Windows/JVM path, not new CI jobs. It covers
controlled pre-capture delay/cancellation, transformed read-through before blocked
disk writes finish, native/file/DB combined barriers, failure cleanup during runtime
shutdown and DB worker termination. One end-to-end .NET regression connects a
synthetic JVM provider to real initial/incremental backups and restores their bytes.
The fixture's game save must flush its memory-only state before either capture.
Actual installed classes are additionally transformed/verified offline without
running game static initializers. These checks are not real-game vehicle/drag tests.

Remaining work is grouped into two product milestones rather than separate helper
features:

- **Consistent capture with a bounded game-thread pause.** Large chunk/animal/native
  input serialization still occupies the game thread. Splitting it across frames
  needs a coherent snapshot or mutation tracking, together with a fixed backup
  input lifetime. The current source is still live; copying files or read-through
  caching alone does not make container/player transfers atomic across files.
- **Real-game acceptance on a disposable world.** Reproduce dragging while saving,
  compare frame times against standard saving, restore discovered/unoccupied
  vehicles and moved items, and exercise mods' OnSave, failure and world exit.
  Only after this is it appropriate to claim the observed gameplay problem solved.

Existing synchronous fallbacks, dependency locks and first file creation can still
stall. Preparation/total durations shown on the card are not frame-time statistics.
### Latest local validation

The integrated Windows Release solution/WinUI/native/Java build passed with zero
warnings and errors. `artifacts/game-extension-tests/combined-save.trx` reports
**149 passed, zero failed, one explicit live-game probe skipped**. This includes the
new source-preparation/initial/incremental/restore pipeline case, existing runtime
pause/death/version cases, provider cancellation and localization/log-filter checks.
The six existing Java harness programs pass, including the combined transformed
file/native/DB barrier and failure cleanup. Installed GameWindow, PlayerDB,
VehiclesDB2, ExceptionLogger, IsoChunk and MapCollisionData bytecode verifies offline;
readiness/database-thread field metadata also verifies without initialization.
The app's four deployed worker JARs and catalogue match the build outputs by SHA-256.

During validation, Windows returned no BasicFileAttributes key, so the initial
read-through attempt correctly fell back to waiting and failed its nonblocking
behavior test. The opened-handle adapter above fixed this; the check was not removed
or replaced with a timestamp. Interruption behavior was also preserved after the
DB fence change. The final .NET set ran once after those Java fixes. No additional
CI job/workflow or repeated full-repository .NET run was introduced.

No user's game was attached or saved, and no user's save, backup DB, settings or
installed application was modified. These are development-worktree and synthetic
fixture results, not live-game acceptance results or GitHub CI results.