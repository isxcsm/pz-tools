# Pre-backup game save bridge

> Current experimental extension integration uses **bootstrap API 6 / save protocol 6**.
> The consolidated request, ownership and remaining-work description is in
> [Game extensions](game-extensions.md). Earlier numbered API notes below describe
> individual changes, not the current deployment version.

> Pause-aware periodic scheduling is implemented separately from the legacy UTC commands described below. It uses runtime observation and guarded SAVE_ACTIVE/PROBE_ACTIVE. Turning off pre-backup saving does not turn off this observation. See [runtime pause architecture](runtime-pause-backups.md). A loaded older bootstrap requires a full game restart.

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Manual and scheduled game backups request `GameWindow.save(true)` on the game
thread before scanning or capturing files when the selected world is active.
The debug save button has been removed.

For an active world, preparation displays a five-second overhead countdown before
the game save: `Saving in 5s` through `Saving in 1s`, then `Save complete` after
the call returns (or `Save failed` on failure). There is no start message at zero.
The app language selects equivalent messages from the shared 18-locale catalog
(`src/PzTools.Process.Contracts/Localization/languages.tsv`). Both the worker and
the Java agent package this catalog; the protocol accepts only its locale tags
(plus the legacy `ko` / `en` aliases), never arbitrary message text. Game font
coverage is controlled by the game, not by the app's Windows UI resources.
Manual backups count down from the request. Periodic backups prepare their worker
and connection ahead of time, carry the original scheduled UTC time to the game,
and display only the final five seconds before that time. A late connection skips
already elapsed numbers instead of adding another five seconds. The save starts
at the due game-loop boundary, without an extra frame delay for a start message.
This is not a real-time guarantee during stalled frames, slow attach or disk contention.
`[scheduler].preparation_lead_seconds` defaults to 8 (range 5-30) to allow connection
startup before the five-second notice. The app countdown keeps the original due
time during preparation and advances to the next interval at that due time.
Each app launch resets the periodic due time to the current time plus the configured
interval, before starting projections or scheduler workers. An overdue reservation
from the previous session is not executed on launch. Worker restarts and unrelated
settings changes do not reset the countdown; pending final/one-shot jobs retain
their separate recovery semantics.
`Save complete` means the game save call returned, not that backup capture or
compression has completed; backup completion remains in the app's progress card.
Settings > Backup > In-game save countdown defaults to on. Turning it off skips
the messages (and the manual five-second delay), without disabling pre-backup saving.
Periodic backups still wait until their scheduled time, even with saving disabled
or the selected game inactive; preparation never captures files early.
It applies to the next worker, including when changed during a running backup.
The app preference `[backup].game_save_countdown` overrides the worker default
`[capture].game_save_countdown`. Disabling pre-backup saving disables all bridge
calls and makes this subordinate toggle unavailable without erasing its preference.

The agent uses `IsoPlayer.getInstance().setHaloNote(...)`, which replaces the same
overhead text object instead of queuing speech. It updates once per second using
monotonic elapsed time at game-loop boundaries, without sleeping on the game
thread. No notice is emitted at zero, and saving is not delayed to render a notice.
The completion message fades using the game's normal halo timer. This shares the
game's halo-note slot: another game or mod notification can replace the message.
The game world is revalidated during countdown and immediately before saving.
A disconnected client cancels a queued/counting-down request, not a save already
in progress. The read-only probe never displays messages or waits for countdown.

Notification API failures do not abort a valid save: the response reports
`notice-unavailable`. One current payload class loader is reused while the payload's
SHA-256 stays unchanged. A changed payload at the same path replaces that loader
between requests. Bootstrap updates or a changed installation path require a game
restart. Previously resident legacy hooks are retired before the first request;
an in-progress old request is rejected as busy rather than forcibly interrupted.
The app and scheduler pass `--save-game` through the backup runner to the worker;
the generic CLI and backup engine remain usable for non-game directories without
attaching to a game. Direct CLI game backups should also pass `--save-game`.
Neither `-debug` nor a Workshop mod is required.

Settings > Backup > Save game before backup is on by default. Turning it off
skips the entire JVM connection and save request in both manual and automatic
backups. This is useful with a separate save mod or when a game update breaks
bridge compatibility. Only on-disk state is then backed up; recent in-memory
changes can be absent after restore. File-copy verification and hashing are
unchanged. The preference is persisted in app settings and read afresh by each
worker. It affects the next backup without restarting the app, not a running job.
Priority: built-in true < `[capture].save_game_before_backup` in the worker TOML
< `[backup].save_game_before_backup` in app settings
< CLI `--save-game-before-backup true|false`. The `--save-game` switch selects
game-backup integration; it does not override this preference.

The preparation runs once per attempt, while holding the repository writer lease,
after recovery and before the USN boundary / full scan. Its returned result is
recorded in `source.prepare.completed`. No running game, no loaded world, or an
explicit current-save mismatch skips the call and proceeds with file backup.
All other errors (including unsupported games, multiple processes, missing bridge,
attach failure and unknown completion) abort that backup without advancing its
revision or checkpoint. The failed run records the `source.prepare` phase. There
is no automatic immediate retry of the save command.

Before attaching, preparation probes the selected world's `players.db` using the
same activity lane as save discovery. It reads fresh file sharing state, not a
cached/debounced activity snapshot. An inactive world skips the entire JVM
connection even if the game is open at its menu or playing another save. Unknown
activity (missing database or access failure) does not count as inactive: the
bridge still validates the world and path on the game thread immediately before
calling save. The UI labels preparation as a check and distinguishes a returned
save call from a skipped save; entering preparation alone does not mean a save
command was sent.

## Design and limits

- A bundled Java Attach helper discovers a JVM-scoped bootstrap through an authenticated
  loopback endpoint. It loads the bootstrap only when absent, not once per save.
  A per-user OS file lock serializes bootstrap initialization across worker processes.
  The game installation and its launch options are not modified.
- A tiny Windows JVMTI bootstrap first loads the running JVM's own `jli.dll`.
  The native game launcher does not preload it, so directly loading the Java
  instrumentation agent otherwise fails with a missing dependency. This uses
  the regular Attach API, not remote-thread injection or changes to DLL search
  paths. No DLL from our bundled runtime is loaded into the game.
- The agent installs one minimal callback at `zombie.GameWindow.logic()V` using the
  Java class-file API. The bootstrap owns one transformer for the JVM lifetime;
  request completion releases only its owner/callback/pending state. There is no
  install/uninstall retransformation for each save. An idle frame reads a volatile
  callback and returns immediately. Other agents' transformations are preserved.
  A disconnect cancels queued/countdown work, but cannot release ownership during
  `save(true)`. The game call must return before the next request can run.
- One daemon control listener remains bound to IPv4 loopback. Its random 256-bit
  credential is discoverable only through the target's Attach system properties.
  It accepts a bounded session handoff, not arbitrary Lua or Java code. The payload
  path is pinned at bootstrap initialization. Each request retains the separate
  temporary callback authenticated by PID and a fresh random 256-bit token. An
  ambiguous endpoint/dispatch failure never triggers another load or save retry.
- `SAVE`, `SAVE_COUNTDOWN`, `SAVE_AT` and diagnostic-only `PROBE` remain supported. Protocol 6 supports `PREPARE_SAVE` and guarded `PREPARE_SAVE_ACTIVE` for an optional save provider.
  They are handled on `GameWindow.gameThread`; PROBE validates the world but never
  invokes save. Protocol 3 introduced `SAVE_COUNTDOWN`. Protocol 4 adds a fixed
  epoch-millisecond due time and an `off` notice mode to `SAVE_AT`. Language
  selectors now accept the shared catalog's 18 tags and legacy `ko`/`en` aliases;
  they cannot execute arbitrary text or code. Catalog rows are compiled into a
  payload class because the unchanged stable bootstrap snapshots classes only.
- The exact current save directory is checked against the selected directory.
  Main menu/loading states, multiplayer, no-save modes, concurrent bridge
  requests, and unsupported signatures are rejected.
- A queued request expires after 15 seconds so resuming a stalled game cannot
  unexpectedly execute an expired request. A running save is never forcibly
  interrupted. Missing completion responses are reported as unknown, not success.
- The actual call is `GameWindow.save(true)`, the same target used by the Lua
  global `save(true)`. Calling it directly lets the bridge report propagated
  exceptions instead of the Lua wrapper swallowing them. The game also catches
  some errors internally, so a returned call is not a disk-integrity guarantee.
- This experimental adapter targets the inspected Java 25 / Build 42 method
  layout. Game updates, attach restrictions, permissions, and other agents may
  affect compatibility. No memory-injection fallback is attempted.
- It does not pause the game for the entire subsequent backup. Cross-file
  snapshot consistency is not guaranteed. Existing stable-copy checks, retries,
  always-included databases, and fallback content hashing remain enabled.

## Component ownership

- `PzTools.SaveBridge` is the C# connection client: process discovery, authenticated
  requests, deadlines and result decoding. It does not decide backup policy.
- `PzTools.Zomboid.Backup` owns the pre-backup policy, including which explicit
  no-save responses may proceed with a disk-only backup. The generic backup engine
  still accepts a preparation callback and has no JVM dependency.
- `PzTools.SaveBridge.Agent` owns the Java Attach entry point and the agent that
  runs inside the game. The wire protocol and game-version-dependent reflection
  live here. Its MSBuild `.proj` also produces the small Attach runtime.
- `PzTools.SaveBridge.Native` owns the Windows JVMTI bootstrap and its native build.
- `build/SaveBridgePayload.targets` connects these build projects to the backup
  worker and copies their output into its `save-bridge` deployment directory.

The solution exposes the Java/native sources and `.proj` files as solution folders
under **src / Save bridge**. They are real MSBuild build units, not dummy C#
assemblies. The backup worker's build invokes them automatically. The C# client
and backup policy are normal, separate C# projects.

Runtime process boundaries are unchanged: the backup worker uses the client,
a short-lived Java helper discovers the bootstrap, and the save itself executes on
the game thread. The bootstrap retains an idle dispatch hook and control listener.
See [gameplay load work](gameplay-background-load.md) for measured scope and remaining costs.

## Building and publishing

Use a Windows x64 Java 25 JDK (not the game's trimmed JRE) and Visual Studio's
x64 C++ build tools:

```powershell
dotnet build src/PzTools.Backup.Cli/PzTools.Backup.Cli.csproj -p:JdkPath=C:\path\to\jdk-25
./scripts/build-save-bridge.ps1 -JdkPath C:\path\to\jdk-25
./scripts/test-save-bridge.ps1 -JdkPath C:\path\to\jdk-25
./scripts/publish-app.ps1 -Configuration Debug -JdkPath C:\path\to\jdk-25
```

`JdkPath` takes precedence over `JAVA_HOME`. If neither is set, exactly one bundled
Java 25 JDK under `artifacts/toolchains` is selected; multiple candidates require
an explicit choice. Output defaults to `artifacts/save-bridge/<Configuration>`.
Use `-p:SaveBridgeDirectory=...` for MSBuild or `-SaveBridgeOutput ...` in publishing
scripts to choose a separate build-output directory, especially while an earlier
native DLL is still loaded by a running game. Do not use the installed app's
directory as a build-output directory. Build metadata stays in the build output
and is not deployed. Unchanged Java/native components are not recompiled.

The build packages only our classes and a small `jlink` Attach runtime. The game
JAR is inspected locally but is not a compile-time or distributed dependency.
Both Debug and Release backup workers include the Java payload. The publishing
scripts use the same dependency graph as a normal worker build; no game JAR is redistributed.

For diagnostics, `GameSaveClient.RequestAsync(pid, savePath, save: false)`
performs the same connection and game-thread checks without saving. Keep live-game
save tests manual; synthetic JVM integration tests use isolated temporary data.

## Optional game extensions

The [separate save module](game-extensions.md) is selected only for an explicit
extension request. Standard saving still calls the original GameWindow.save(true).
The B42.20 extension calls VersionedSaveEntry.saveForBackup using private generated
companions; it does not rewrite GameWindow.save or the public chunk/native save
and read/write paths. Nested saves from other mods remain normal saves.

Bootstrap API 9 and matched app/worker/JARs are required. Older residents need one restart; compatible
API9 payload/module changes use the [idle reload lifecycle](module-reload.md). The wire
protocol remains 6. PREPARE_SAVE_ACTIVE combines provider selection, explicit version
override and the same pause/death/permission guard used by the scheduling authority.
STATE3 carries live facts and the actual provider result. It is not a second poller.

Private chunk I/O uses the original counted file locks. The private native-save copy
can defer its completion wait after the existing native worker starts and the original
snapshot lock is secured. Public native save/stop bodies are not modified. Four
nonthrowing read-only DB/error/native-phase observers support completion accounting.
The retired global save/read-through rewrites are not reintroduced. A typed
GAME_SAVE_AND_PENDING_WRITES_DRAINED receipt follows owned file/native work and required
DB drains. It is not an atomic whole-world or hardware-flush receipt. Private readiness
also waits for an inventory drag/drop to finish; it never clears or restores a drag.
Bounded per-request stage timings travel in the existing result detail, not a new poller.

Unsupported private sources fall back to standard saving before capture begins.
After mutation starts, errors or unknown completion are never replayed as another
standard save. RecoveryStamp, readiness, cancellation admission, game-thread/world
identity and the general backup-preparation boundary remain in force.
