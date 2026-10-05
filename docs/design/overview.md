# How PZ Tools fits together

[Documentation index](../README.md)

This is the map for someone about to change the code. Each design page covers one area in depth and assumes you
know where that area sits; the [glossary](glossary.md) defines the terms.

PZ Tools is a WinUI 3 app (.NET 10, x64, running as administrator) plus a set of small executables that do the work.
The app shows state and starts work; two schedulers decide when work is due; runners and workers each do one job in
their own process. Inside the running game, a Java bridge saves the game on request, streams its state and hosts
optional extensions.

<a id="the-pieces"></a>
## Projects

The .NET projects are in [`PzTools.sln`](../../PzTools.sln). Libraries target `net10.0`; executables, the app and
the benchmarks target `net10.0-windows`. The Java and C++ parts are MSBuild `.proj` files that appear in the
solution as folders. They are built through [`build/GameBridgePayload.targets`](../../build/GameBridgePayload.targets)
when `PzTools.State.Scheduler` or `PzTools.Backup.Cli` builds, or by `scripts/build-game-bridge.ps1`.

| Project | Kind | Owns |
| --- | --- | --- |
| `PzTools.App` | WinUI app | Window, pages, tray, hotkeys, crash reports. The only project that uses WinUI. |
| `PzTools.App.Core` | Library | `AppHost` (start-up, scheduler supervision, projections), `OperationCoordinator` (starts workers for the UI), settings, game memory, recording service, update check |
| `PzTools.Projections` | Library | Views the UI reads: state, backups, schedule, telemetry cards, `logs.db` |
| `PzTools.Process.Contracts` | Library | Command-line parsing, result envelope, component configuration and options, path layout, failure payloads, game process finder, language list |
| `PzTools.Process.Hosting` | Library | Child processes and job objects, named mutexes, stop and yield events, detached launch, the runtime state pipe |
| `PzTools.Process.Telemetry` | Library | Per-component process telemetry store and sessions |
| `PzTools.Control` | Library | `control.db` and run index allocation |
| `PzTools.Scheduling` | Library | `scheduler.db`, backup and state scheduler logic, game-aware timing, orphan cleanup dispatch |
| `PzTools.Backup.Scheduler`, `PzTools.State.Scheduler` | Executables | The two long-running schedulers |
| `PzTools.Backup.Runner`, `PzTools.Maintenance.Runner`, `PzTools.State.Runner` | Executables | Take a mutex, run one worker |
| `PzTools.Backup.Core` | Library | Backup options and configuration, file catalog and diff, scanning |
| `PzTools.Backup.Storage` | Library | `repository.db`, packs, writer lock, backup-engine telemetry store |
| `PzTools.Backup.ChangeTracking.Windows` | Library | USN journal reader, Windows file identity and times |
| `PzTools.Backup.Engine` | Library | Initial and incremental backup, stable capture, restore, maintenance, housekeeping, orphan cleanup, crash recovery |
| `PzTools.Backup.Cli` | Executable | Backup worker (`backup`), restore and repository commands |
| `PzTools.Maintenance.Cli` | Executable | Maintenance dispatch and the heavy maintenance lanes |
| `PzTools.Backup.Benchmarks` | Executable | Backup performance profiles; not shipped |
| `PzTools.Zomboid.State` | Library | `state.db`, save discovery, activity, collector and reactor |
| `PzTools.State.Collector.Cli`, `PzTools.State.Reactor.Cli` | Executables | The state check's two steps as separate processes, for the state runner |
| `PzTools.Zomboid.Backup` | Library | Asking the game to save before a backup, character metadata of revisions |
| `PzTools.Zomboid.Archive`, `PzTools.Zomboid.Archive.Cli` | Library, executable | ZIP import and export |
| `PzTools.Zomboid.Recovery`, `PzTools.Zomboid.Recovery.Cli` | Library, executable | Healing and reviving characters |
| `PzTools.Profiling`, `PzTools.Profiler.Cli` | Library, executable | Performance recordings: conversion, analysis, the recording worker |
| `PzTools.GameBridge` | Library | C# clients of the game bridge: save, WATCH, extension control, profiler, notices |
| `PzTools.GameBridge.Agent` | Java (MSBuild `.proj`) | Bridge bootstrap and payload jars, attach helper, the bundled Java runtime |
| `PzTools.GameBridge.Native` | C++ (MSBuild `.proj`) | `pztools-attach-bootstrap.dll` |
| `PzTools.GameExtensions` | Library | Extension catalogue, settings store, vehicle settings |
| `PzTools.GameExtensions.Java` | Java (MSBuild `.proj`, built by the vehicle module's project) | Extension API and runtime (`ModuleHost`) |
| `PzTools.GameExtensions.VehicleDrivetrain` | Java (MSBuild `.proj`) | The vehicle controls module |

Tests are in `tests/`: `PzTools.Backup.Tests` (the main xUnit suite), `PzTools.CrashFixture`, the UI smoke
projects (`*Smoke`), and Java and fake-game fixtures run by `scripts/test-game-bridge.ps1` and
`scripts/test-game-extensions.ps1`. See [development](../contributing/development.md).

`PzTools.App` uses `App.Core` and the view and contract types; it does not call the storage or engine libraries to
do work, so another front end could sit on `App.Core`. The libraries build for any platform, but nothing else is
built or tested, and these parts are Windows-only: USN change tracking, `WindowsFileMetadataReader`, job objects,
named events and detached launch in `Process.Hosting`, and the native attach DLL.

## Processes

```text
PzTools.App
 ├─ PzTools.Backup.Scheduler ─► Backup.Runner ─► Backup.Cli backup ──── save request ──┐
 │                           └► Maintenance.Runner ─► Maintenance.Cli dispatch          │
 │                                                     └► lanes (detached)              │
 ├─ PzTools.State.Scheduler ─── WATCH, extension control ──────────────────────────────►│ game bridge
 │      └► Maintenance.Cli --lane OrphanBackups (detached)                              │ (in the game)
 └─ one worker per operation: restore, ZIP, character recovery, profiler, state refresh ┘
```

Every connection to the game goes through a short-lived attach helper (the bundled `java.exe`) that loads or
reaches the bridge and connects it back to the caller over loopback with a one-time secret. The state scheduler
shares what the game reports with the backup scheduler and the app over a named pipe. Command lines, mutexes,
databases and supervision are in [process architecture](process-architecture.md).

## Where data lives

| Place | Contents |
| --- | --- |
| App folder | Executables, `defaults\`, `game-bridge\` (jars, DLL, Java runtime, extensions). Never written. |
| `%LOCALAPPDATA%\PzTools` | `settings.toml`, `config\<component>\default.toml`, `control.db`, `state.db`, `scheduler.db`, `logs.db`, `operations\`, `profiles\`, `crash\`, `extensions\settings.json` |
| Backup folder (default `%USERPROFILE%\Zomboid\Backups`) | `repository.db`, packs, `telemetry.db`, `.writer.lock`, `.pztools\` process telemetry |
| `Zomboid\Saves` | The saves. Written only by restore, import, character recovery and deleting a save. |
| Game folder | Only `ProjectZomboid64.json`, and only when the player sets the game's memory ([game memory](game-memory.md)) |

The full list is in [files and folders](../reference/files-and-folders.md).

## One automatic backup, end to end

With **Delay scheduled backups while paused or asleep** on (game-aware timing):

1. The state scheduler holds a WATCH stream to the game. When the game reports a loaded world whose save is under
   the configured `Saves` folder, two matching checks confirm it active and the reactor sends `ActivateTarget` to
   `scheduler.db`.
2. The backup scheduler counts only active play time. When an interval of it has passed, it admits a backup with a
   ticket for that process, observer epoch and world ([game-aware timing](runtime-pause-backups.md)).
3. It reserves a workflow under a new run index, asks running maintenance lanes to yield, checks the admission
   again, and starts `PzTools.Backup.Runner`.
4. The runner takes the repository mutex and starts `PzTools.Backup.Cli backup`. The worker takes the writer lock,
   cleans up after any crashed backup, and asks the game to save through the bridge. The game checks the ticket
   again and runs its own save ([game bridge](game-bridge.md)). If the game cannot be reached, the backup goes on
   with the files on disk.
5. The worker finds changed files from the USN journal, or by scanning when it cannot
   ([USN tracking](usn-journal.md)), copies each until the copy is consistent
   ([stable capture](stable-capture.md)), stores new contents in packs, and commits one revision to
   `repository.db` ([repository format](repository-format.md)). Until that commit the backup does not exist.
6. The scheduler starts `PzTools.Maintenance.Runner`, which marks automatic backups beyond retention as deleted and
   starts the heavy lanes detached; they wait until the game is closed ([housekeeping](repository-housekeeping.md)).
7. The app's projections pick up the new revision and the worker's telemetry and update the cards and the save list
   ([telemetry](telemetry.md)).

With game-aware timing off, step 1 uses whether the game has the save's `players.db` locked, and step 2 counts wall
clock time. A death backup takes the same path, admitted by a death reported on WATCH
([live character death](runtime-character-death.md)).

## How the app follows the game

The state scheduler is the only process that keeps a link to the game for state. It finds the one game process,
starts the attach helper for a WATCH stream, and publishes each reading. The backup scheduler uses the
readings for timing, ticket admission and death backups; the app uses them for the home page, the countdown, game
versions and extension status. Each reading has a quality (`Fresh`, `Stale`, `Offline`, `Ambiguous`,
`Unsupported`, `Unknown`) and, when not fresh, a reason such as `connecting`, `game-starting` or
`runtime-restart-required` ([`RuntimeContracts.cs`](../../src/PzTools.Process.Contracts/GameRuntime/RuntimeContracts.cs)). The same process holds a separate extension-control connection that applies the
extension settings and holds the control lease ([game extensions](game-extensions.md)). When the game cannot be
read, backups fall back to the files on disk and wall-clock timing after a 90-second grace period.

The bridge's bootstrap stays in the game until it exits; the payload, the extension runtime and the modules can be
replaced while it runs ([replacing code in a running game](module-reload.md)).

## Where to read next

| To change | Read |
| --- | --- |
| Processes, locks, start-up, supervision, crash recovery | [Process architecture](process-architecture.md) |
| Backup storage | [Repository format](repository-format.md), [pack format](pack-format.md), [compact repository format](compact-repository-format.md), [path normalization](path-normalization.md) |
| Finding and copying changed files | [USN tracking](usn-journal.md), [stable capture](stable-capture.md) |
| Retention, cleanup, orphan backups | [Repository housekeeping](repository-housekeeping.md) |
| When automatic backups run | [Game-aware timing](runtime-pause-backups.md), [live character death](runtime-character-death.md) |
| Talking to the game | [Game bridge](game-bridge.md), [replacing code in a running game](module-reload.md) |
| Extensions | [Game extensions](game-extensions.md), [vehicle controls](vehicle-drivetrain.md) |
| Healing and reviving characters | [Character recovery](character-recovery.md) |
| Performance recordings | [Profiler](profiler.md) |
| Game memory setting | [Game memory](game-memory.md) |
| Progress cards, logs, crash reports | [Telemetry](telemetry.md) |
| Screens and behaviour of the UI | [UI contract](ui-ux-contract.md), [UI assets](ui-assets.md) |
| Building and testing | [Development](../contributing/development.md) |
