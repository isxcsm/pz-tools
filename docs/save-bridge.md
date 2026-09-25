# Pre-backup game save bridge

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
`notice-unavailable`. Each request loads the current implementation in a disposable
class loader; app updates/restarts do not require a game restart to replace save
or notification code. Previously resident bridge hooks are retired before the
new request is installed. An in-progress old request is rejected as busy rather
than forcibly interrupted.
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

- A bundled Java Attach helper loads a small stable bootstrap into the game JVM;
  that bootstrap loads the current implementation JAR for each request.
  The game installation and its launch options are not modified.
- A tiny Windows JVMTI bootstrap first loads the running JVM's own `jli.dll`.
  The native game launcher does not preload it, so directly loading the Java
  instrumentation agent otherwise fails with a missing dependency. This uses
  the regular Attach API, not remote-thread injection or changes to DLL search
  paths. No DLL from our bundled runtime is loaded into the game.
- The agent adds a callback at the start of `zombie.GameWindow.logic()V` using
  the Java class-file API. The request owns its transformer and removes it, then
  retransforms the method to remove our callback before reporting completion.
  Other agents' transformations are preserved. Disconnect/app exit cancels a
  queued/countdown request and removes the hook; an already running save finishes
  before removal. There is no idle game-loop callback after a completed request.
  JVM-loaded bootstrap classes/native libraries can remain inert until game exit;
  this is not a promise of immediate class unloading. Legacy transformer objects
  whose old implementation lost their removal handle are disabled via public
  retransformation, so they cannot reinsert the old callback.
- Each request opens a temporary loopback callback connection authenticated by
  a random 256-bit token and expected game PID. There is no persistent listening
  port in the game and no arbitrary Lua/code evaluation command.
- `SAVE`, `SAVE_COUNTDOWN`, `SAVE_AT` and diagnostic-only `PROBE` are the commands.
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
a short-lived Java process attaches the agent, and the save itself executes on
the game thread. There is no additional CLI wrapper or background service.

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
