# Game bridge

[Documentation index](../README.md)

The game bridge is the Java code PZ Tools loads into the running Project Zomboid process. It saves the game
on request before a backup, streams the game's state to the scheduler, hosts the
[game extensions](game-extensions.md) and records [performance profiles](profiler.md). This page covers how
it gets into the game, what it changes there, the save request and what each outcome means for a backup.

What the player sees is described in [backups](../reference/backups.md#saving-the-game-before-a-backup) and
[troubleshooting](../guides/troubleshooting.md). Timing of automatic backups is in
[game-aware timing](runtime-pause-backups.md).

## Components

The build puts these files in `game-bridge\` next to the workers:

| File | Runs in | Role |
| --- | --- | --- |
| `runtime\` | Attach helper | A `jlink` image of the build JDK with `jdk.attach` and `jdk.jfr`. It runs the attach helper and is never loaded into the game. |
| `pztools-game-bridge.jar` | Helper and game | `pztools.bridge.AttachMain` (the helper's main class) and the payload (`pztools.bridge.runtime.*`) |
| `pztools-game-bootstrap.jar` | Game | `AgentEntry` and the extension API classes. Loaded once per game process; built with fixed timestamps so its bytes do not change between builds. |
| `pztools-attach-bootstrap.dll` | Game | A JVMTI agent that loads the game's own `jli.dll` |
| `extensions\` | Game | Extension runtime, modules and catalogue ([game extensions](game-extensions.md)) |

On the app side:

| Code | Responsibility |
| --- | --- |
| [`PzTools.GameBridge`](../../src/PzTools.GameBridge) | Starting the helper, authenticated connections, deadlines, parsing results. `GameSaveClient` (save requests), `GameRuntimeClient` (state stream), `GameProfileClient`, `GameExtensionClient`, `AttachDiagnostics` |
| [`PzTools.Zomboid.Backup`](../../src/PzTools.Zomboid.Backup) | Deciding what a save result means for a backup: `BackupGameSave`, `BackupTimingPreparation`, `GuardedGamePreparation` |
| [`PzTools.State.Scheduler`](../../src/PzTools.State.Scheduler) | `RuntimeObservationCoordinator` keeps the state stream connected and publishes observations |
| [`PzTools.GameBridge.Agent`](../../src/PzTools.GameBridge.Agent) | Java sources of the helper, bootstrap and payload |
| [`PzTools.GameBridge.Native`](../../src/PzTools.GameBridge.Native) | The native bootstrap |

The backup engine knows nothing about the game. It receives a preparation step to run before capture, and
runs it while holding the repository's [writer lock](glossary.md#writer-lock).

<a id="getting-into-the-game"></a>
## Attaching

Every connection, whether a save request, the state stream (`WATCH`) or extension control (`EXTENSIONS`),
starts the same way:

1. The client finds exactly one game process (`GameProcessFinder`): `ProjectZomboid64`, `ProjectZomboid32`
   or `ProjectZomboid`, or a `java`/`javaw` process whose command line names the class
   `zombie.gameStates.MainScreenState`. None gives `game-not-running`, several give `multiple-games`.
2. It opens a TCP listener on 127.0.0.1 with a random port, makes a 64-hex-digit token and starts
   `runtime\bin\java.exe --add-modules jdk.attach -jar pztools-game-bridge.jar <pid> <jar> <port> <token> [WATCH|EXTENSIONS]`.
   The environment variable `PZTOOLS_GAME_ACCOUNT` names the account the game runs as (see below).
3. The helper takes `%USERPROFILE%\.pztools-bridge\bootstrap.lock` and holds it through the attach, the
   version check and the handshake, so helpers from different processes never attach at the same time. It
   attaches with the standard Java Attach API.
4. If the game has no system property `pztools.bridge.control.v1`, this is the first attach since the game
   started. The helper loads `pztools-attach-bootstrap.dll` (`loadAgentPath`), then the bootstrap jar
   (`loadAgent`, option `BOOTSTRAP1:<base64 payload path>`). The bootstrap binds its own listener on
   127.0.0.1, makes a 32-byte secret, and publishes `pztools.bridge.bootstrap.api=11` and then
   `pztools.bridge.control.v1=2:<pid>:<port>:<secret>`.
5. The helper requires `pztools.bridge.bootstrap.api` to be `11`. Any other value means the game still runs a
   bootstrap from another version; the helper stops without sending anything
   (see [restart required](#restart-required-after-an-app-update)).
6. The helper detaches, connects to the bootstrap's port and sends the secret, the app's port and token, the
   payload path and the kind. The bootstrap answers `ACCEPTED`, `BUSY`, `PAYLOAD_UNAVAILABLE`, `REJECTED` or
   `RESTART_REQUIRED`. Anything but `ACCEPTED` makes the helper exit with an error; no command was sent.
7. On `ACCEPTED` the bootstrap runs the payload's entry point on a new daemon thread. It connects back to the
   app's listener and identifies itself with the process id and token: `HELLO\t6\t<pid>\t<token>` for a
   request, `RUNTIME\t1\t<pid>\t<token>` for the state stream, `EXTENSIONS\t1\t<pid>\t<token>` for extension
   control. The client rejects any other greeting (`authentication-failed`).

The native bootstrap exists because the `instrument` agent library needs `jli.dll`, and some embedded Java
launchers neither load it nor put the runtime's `bin` folder on the DLL search path. The DLL finds the
game's own `jvm.dll` (`bin\server\jvm.dll`) and loads `jli.dll` from the `bin` folder beside it. It does not
change the process's DLL search path and loads nothing from PZ Tools' runtime. This is a standard JVMTI
agent load: there is no remote-thread injection and no fallback that edits game files.

Anyone who can attach to the game can read the secret, and attaching already lets a program run code in the
game, so the secret adds nothing an attacher lacks. It keeps other local programs that cannot attach off the
listener. The listener accepts a fixed set of commands; it never runs Lua or Java code sent to it. The
payload it loads is a jar named by path, the one in PZ Tools' own folder.

### Folders with letters outside ASCII

The game's Java misreads a non-ASCII path for the two files handed to it by path: the native bootstrap and the
bootstrap jar. When the app's folder has such a path, the helper (`AttachMain.attachable`) copies each of the
two, named by the first 16 hex digits of its SHA-256, to a folder whose path is ASCII, and hands that copy
over. Everything after the bootstrap is read by Java from its own path and needs no copy.

The game loads the copy as code, so only the user may change it:

- The first choice is `%TEMP%\PzTools\attach\s-<account hash>\<digest>\` if `%TEMP%` is ASCII, else the same
  under `%ProgramData%`. A new folder gets an ACL that allows only the two principals below.
- An existing folder or copy is used only if it is owned by one of them, nobody else may write it, and the
  game's account may read it. A matching copy a running game holds open is reused as it is.
- With no usable folder the helper falls back to the file's own path.

The two principals are the game's account and the account the helper creates files as. The app runs as
administrator, so its files belong to the Administrators group, while the game runs unelevated as the player.
The app reads the game's account from the game's process token (`AttachDiagnostics.AccountOf`), which is
right even when the app was started with another administrator's password. Without it the helper uses
`USERDOMAIN\USERNAME`, and without that the creator alone.

## Inside the game

### The game-loop hook

The first request that needs the game thread calls `AgentEntry.ensureGameHook`. It requires Java feature
version 25 with class retransformation, exactly one loaded `zombie.GameWindow`, exactly one `logic()V`, a
static `void save(boolean)`, a `gameThread` field, and the bootstrap class visible from the game's class
loader. It then retransforms `GameWindow` to insert one static call, `AgentEntry.poll()`, at the start of
`logic()`. Any failed check refuses the request.

The transformer stays registered. When another agent retransforms `GameWindow` later, the JVM runs it again
on the original bytes, so both changes survive. A failure at that point leaves the class without the call and
is counted in the `hookFailures` diagnostic.

`poll()` runs up to three callbacks each frame: the state observer (with the optional profiler), the extension
lifecycle, and the pending request. An observer or lifecycle callback that throws is dropped.

### Layers

| Layer | Holds | Replaced while the game runs? |
| --- | --- | --- |
| [Bootstrap](glossary.md#bootstrap) (`AgentEntry`) | Control listener, game-loop hook, payload loading | No |
| [Payload](glossary.md#payload) | Save requests, state stream, extension control, profiling, leases | Yes |
| [Extension runtime](glossary.md#extension-runtime-host) and modules | Game extensions | Yes, each on its own |

The payload jar must declare `PzTools-Bootstrap-Api: 11` in its manifest, or the bootstrap answers
`PAYLOAD_UNAVAILABLE`. A jar with the same digest as the loaded one is reused, also from a new folder after the
app has moved. For a new digest the bootstrap answers `BUSY` at once if a request session (save, profiler or
notice) is running. Otherwise it links the new jar, asks WATCH and extension control to end, pauses dispatch
and waits up to 3 seconds for every session and callback to finish before switching. If they do not,
it answers `BUSY` and keeps the old payload. See [component updates](module-reload.md).

On its first save request the payload also disarms any `pztools.bridge.SaveBridge` classes left in the game by
versions older than the bootstrap design (`LegacyBridgeRetirement`). If that old code still has a request
pending, the new request is refused as `busy`.

### What changes in the game, and what does not

Changed, in memory only, until the game exits:

- one static call at the start of `GameWindow.logic()`;
- the system properties `pztools.bridge.control.v1` and `pztools.bridge.bootstrap.api`;
- daemon threads: the control listener and one per open session;
- the per-frame state read and, for a living character, the `pztools.recovery.*` keys in the player's
  modData ([character recovery](character-recovery.md#the-identity-stamp));
- a halo note above the player during a save, when notices are on;
- whatever an enabled extension does ([game extensions](game-extensions.md)).

Not changed: game files, launch options, Workshop mods and Lua code. The game is saved only through its own
`GameWindow.save(true)`, and only when a request asks for it. The bridge stays loaded after PZ Tools exits;
what PZ Tools asked for ends with its [lease](#leases).

## The save request

### Commands

`GameSaveClient` sends one command line per request:

| Command | Used for |
| --- | --- |
| `SAVE`, `PROBE` | A manual backup. `PROBE` runs the same checks without saving (tests use it). |
| `SAVE_COUNTDOWN` | An unguarded automatic backup with notices and no due time: a 5-second countdown. Only a queued one-off run without a ticket takes this path (`SAVE` with the countdown off); the scheduler queues none today, since death backups are guarded and older one-off commands are dropped. |
| `SAVE_AT` | A wall-clock periodic backup with its due time, at most one minute ahead |
| `SAVE_ACTIVE`, `PROBE_ACTIVE` | A guarded backup carrying a [ticket](glossary.md#ticket): game-aware periodic and death backups. `PROBE_ACTIVE` when **Save game before backup** is off. |
| `PREPARE_SAVE`, `PREPARE_SAVE_ACTIVE` | A save provider from an extension. No shipped extension provides one; only test fixtures use this path. |

Each carries the save path (base64), the queue timeout and the completion timeout. The game rejects a queue
timeout outside 1–60 s, a completion timeout outside 30–600 s, or a completion timeout less than the queue
timeout plus 20 s. Defaults are 15 s and 150 s, and 30 s to connect; they are the `[runtime]` keys in
[advanced settings](../reference/advanced-settings.md).

### In the game

`BridgeSession` handles a request:

1. It takes request ownership (`AgentEntry.acquire`). One request runs at a time; a second gets `busy`.
2. It installs the hook and, for a ticket, reserves it: the ticket's ordinal (the run index) must be higher
   than any seen by this observer, or the request is deferred as `runtime-request-replayed`.
3. It waits for the game thread to pick the request up. If the queue timeout passes first, the request is
   cancelled with `queue-timeout` and nothing is saved. Otherwise the client receives `RUNNING`.
4. On the game thread, every frame until it saves:
   - it refuses to run on any other thread (`wrong-thread`);
   - it checks the ticket (see [admission](runtime-pause-backups.md#admission)), which also gives the time
     left until the backup is due;
   - it validates the world when the request starts and then every second;
   - it shows the countdown notice, if any, and waits until the due time;
   - it checks the ticket once more, then moves the request from *countdown* to *saving* with one
     compare-and-set. The client is sent `SAVING`.
5. For a save, it writes the [recovery stamp](character-recovery.md#the-identity-stamp), then calls
   `GameWindow.save(true)` on the game thread.
6. When the call returns, the client receives `OK` with a detail string: the thread, elapsed milliseconds and
   save path, plus `recovery-metadata-unavailable=` or `notice-unavailable=` if either failed. Neither
   failure stops the save.

The world validation refuses:

| Check | Code |
| --- | --- |
| `GameClient.client`, `GameClient.clientSave` or `GameServer.server` is set | `multiplayer` |
| The current state is not `IngameState`, or there is no world or cell | `not-in-world` |
| `Core.isNoSave()`, or the mode is `LastStand` or `Tutorial` | `saving-disabled` |
| `ZomboidFileSystem.getCurrentSaveDir()` is not the same folder as the requested save | `save-mismatch` |

The session's own deadline is the completion timeout minus the queue timeout minus 15 s, plus any wait for
the due time. If it passes before saving started, the request is cancelled as `queue-timeout`. If the save call
is still running, the answer is `completion-unknown`.

### Cancellation

For a guarded request the client checks `RuntimePreparationPermit` before sending and then every 100 ms
until it sees `SAVING`. For a periodic ticket the permit is withdrawn when automatic backups are switched
off, the generation or target changes, or game-aware timing is switched off. For a death ticket it is
withdrawn when automatic backups are switched off, the generation changes, the death option is off, or the
facts no longer show this death on this save. The client then sends `CANCEL\t<request id>`. The game's compare-and-set
decides the race: a cancel before *saving* defers the request as `runtime-reservation-cancelled`; after it,
the cancel loses and the save completes.

A closed connection cannot release ownership while `save(true)` runs. The session waits for the call to
return before the next request can use the game thread.

### Notices

`SaveNotice` replaces the player's halo note (`IsoPlayer.setHaloNote`); it adds no chat line and no timer
thread. The countdown shows only during the last 5 seconds before the due time, then *saving*, then done or
failed. The saving note is refreshed while the save runs, since the game fades halo notes by game time. A
notice stops for good if the player, world, cell or game state changes.

| Backup | Notices |
| --- | --- |
| Manual | None: the worker passes no notice language, and the save runs at once |
| Game-aware periodic | Countdown from 5 s, since the request is sent 8 s before the due time (`preparation_lead_seconds`) |
| Death | No countdown (the ticket's due time is now); *saving* and the result |
| Wall-clock periodic | Countdown from 5 s to the due time, also sent 8 s early |

With **In-game save countdown** off, no notices are shown at all.

### Busy

When the bootstrap answers `BUSY` (another short request, such as a hotkey's note or a recording starting, or
a payload reload), the helper reports "still active" and nothing was sent. `GameSaveClient` starts the helper
again every 0.5 s for up to 10 s, then fails with `busy`.

<a id="admission-and-failures"></a>
## What each outcome means for a backup

How a result is handled depends on whether the backup is manual, wall-clock automatic or guarded:

| Result | Manual | Wall-clock automatic | Guarded (game-aware periodic, death) |
| --- | --- | --- | --- |
| The save's `players.db` opens exclusively (inactive by its file lock) | No contact; files on disk are backed up | Skipped before contacting the game | Not checked; the game's guard decides |
| The file lock gives no answer (`Unknown`: missing file, access denied, I/O error) | The game is asked as usual | Skipped: only a save confirmed `Active` is backed up | Not checked |
| `game-not-running`, `not-in-world`, `save-mismatch` | Files on disk are backed up | Skipped | Failed, slot used |
| Game unreachable: `attach-failed`, `attach-disabled`, `connection-timeout`, `bridge-not-built`, `unsupported-protocol`; or the bridge does not fit the game: `unsupported-runtime`, `unsupported-loader`, `unsupported-game`; or several games run and none is picked: `multiple-games` | Files on disk are backed up, with a `save-unavailable` warning | The same | The same |
| `runtime-deferred` (any reason), `queue-timeout` | Failed | Failed | Skipped; the slot is kept |
| `busy`, `missing-save`, `multiplayer`, `saving-disabled`, `wrong-thread`, `save-failed`, `bridge-failed`, `protocol`, `authentication-failed` | Failed | Failed | Failed, slot used |
| `completion-unknown`, `invalid-response` | Failed | Failed | Failed; the periodic schedule waits one interval ([why](runtime-pause-backups.md#when-a-backup-attempt-fails)) |

"Slot" applies to the game-aware periodic schedule. A death backup has no slot: its queued run is kept only
when the worker reports `Skipped` and is deleted after any other outcome of a started worker, including
`completion-unknown` ([one death, at most one backup](runtime-character-death.md#one-death-at-most-one-backup)).

A failed save fails the backup with `game-save-<code>`. Wall-clock automatic backups also check that the save
is still in use (its file lock, `AutomaticBackupActivity`) after the save returns, and are skipped if it is
not.

The split between "unreachable" and the rest is deliberate. When the helper could not reach the game, nothing
was asked of it, so the files on disk are all there is and a backup of them beats none. Once the game has been
asked, an error or an unclear answer is not taken as permission to copy files it may still be writing.

So does `multiple-games`: with more than one game process running, the client picks none and attaches to none,
so no game was asked. Asking each in turn would put the bridge into a game the player did not mean.

The unsupported codes belong with "unreachable" for the same reason. They come from `BridgeSession.install`,
which sets the payload up in the game before any request is queued. A game update that renamed or removed what
the bridge hooks (a missing method, field or class) is reported there as `unsupported-game` rather than the
generic `bridge-failed`, which could also mean a failure after the request was queued.

The `save-unavailable` warning is the `source.prepare.completed` log entry; its detail holds the attach
diagnostics below.

## Restart required after an app update

The bootstrap cannot be replaced in a running game. When an update changes something the bootstrap must know,
the bootstrap API number goes up rather than old names being kept alive in the payload. The helper reads the
API of the bootstrap already in the game before sending anything, and on a mismatch prints "Restart the game to
use the updated bridge".

| Path | What happens |
| --- | --- |
| State stream (`GameRuntimeClient`) | Mapped to `restart-required`. `RuntimeObservationCoordinator` publishes `runtime-restart-required`, marks extensions `RestartRequired`, and does not attach to that process again (same id and start time) until it exits. |
| App (`GameLinkMonitor`) | Shows the link card at once, without the grace period, since the link cannot come back without a restart: **PZ Tools was updated**, **Restart the game.** |
| Periodic backups (`BackupScheduler.WaitsForGameRestart`) | Held until the game is gone or answers again. The schedule line says **Automatic backups after a game restart**. A save the game was not asked to write is not copied, as such backups would push good ones out of the kept number. |
| Save request | The helper's failure is classified as `attach-failed`, so manual backups go ahead with the files on disk |

A game that refuses because it was started with `-XX:+DisableAttachMechanism` is treated the same way by the
coordinator (not asked again until it restarts) but periodic backups are not held.

<a id="when-attaching-fails"></a>
## When attaching fails

The helper's first line on failure is `PZTOOLS-ATTACH-FAILED\t<stage>\t<exception>`, where the stage is
`arguments`, `lock`, `attach`, `native-bootstrap`, `bootstrap`, `bootstrap-version` or `handshake`. A line
`PZTOOLS-ATTACH-HANDED` before it says where each handed file came from (`own`, `own-non-ascii`, `temp-copy`,
`programdata-copy`).

`AttachDiagnostics.Failure` turns that into the failure's `diagnostics` string:

- `stage`, `error` and the exit code;
- whether the app and the game run elevated, and why the game's token could not be read if it could not;
- the game's executable file name;
- `handed=` from the helper;
- whether the app folder, `%TEMP%` and the user profile contain non-ASCII characters (yes or no, never the
  path);
- the Windows version and the last 3000 characters of the helper's output.

Paths are scrubbed: `%TEMP%`, `%LOCALAPPDATA%` and `%USERPROFILE%` replace those folders, and any other
absolute path is cut to its last part.

`AttachDiagnostics.Classify` recognises one cause the player can change: Java reports that the target "does
not support the attach mechanism", which is what `-XX:+DisableAttachMechanism` does. Its code is
`attach-disabled`, and the app says **A game launch option is blocking the connection.** Everything else is
`attach-failed` (on the state stream, `runtime-unavailable`). The app always runs as administrator by its
manifest, so a game with more rights than the app is not a cause.

| Link | Log entry |
| --- | --- |
| State stream | `game.link.failed` from `state-scheduler`, once per game process and code |
| A recording | The recorder's `run.failed` |
| A backup's save request | The `source.prepare.completed` warning |

A busy bootstrap on the state stream is retried and not logged. **Copy details** on the Logs page includes the
diagnostics.

<a id="leases"></a>
## Leases

What the app asks of the game must end once the app has gone, however it went, but must not end each time a
connection drops (the scheduler restarting, a world loading). So it follows a lease, not a connection
(`Leases.java`):

- Each run of the app makes a 32-hex-digit identifier at start (`AppRun`). The game cannot see the app's
  process: the app is elevated and the game is not.
- The state stream sends `LEASE\t<run>` once after connecting, and renews the run's lease every 250 ms while
  it is open. A recording request naming the run renews it too.
- The lease lapses 120 s after the run was last heard from (`pztools.bridge.lease.seconds` overrides it for
  tests).

| Holder | Lease | Ends |
| --- | --- | --- |
| The rolling recording | The app run's | When the lease lapses |
| A recording asked for | The app run's | When the lease lapses, at its stop, or at its maximum length |
| Extension control | Its own connection's, renewed by each command | 5 s without a command, or when the connection closes |

Leases live in the payload. See [profiler](profiler.md) for how the app restarts the rolling recording after
the stream was away long enough for the game to end it.

<a id="compatibility-and-lifecycle"></a>
## Version checks

The bridge stays in the game after PZ Tools closes, so a newer PZ Tools can meet a bridge from an older one.
These numbers decide what happens. This table is the one place they are recorded.

| Contract | Current | Checked between | On a mismatch |
| --- | --- | --- | --- |
| Java runtime | 25, with retransformation | The game's JVM and the bootstrap/payload | `unsupported-runtime` or a refused hook |
| Bootstrap API | 11 | The helper and the bootstrap in the game (system property); the bootstrap and the payload jar (manifest) | Helper: restart required. Payload: `PAYLOAD_UNAVAILABLE`. |
| Save protocol | `HELLO` 6 | `GameSaveClient` and the payload | Payloads speaking 1–4 still serve plain saves with fewer features. A guarded request, non-default timeouts or a due time on an older payload give `unsupported-protocol`. |
| State stream | `STATE5` | `RuntimeSnapshot.ParseWire` and the payload | `STATE1`–`STATE5` are read. A frame missing the required capabilities `runtime.snapshot.v1`, `runtime.active-clock.v1`, `save.guarded.v1` is rejected. `STATE5` adds the game's maximum heap. |
| Extension host ABI | 3 | The extension runtime and each module | The module is not loaded |
| Extension control wire | 1 | `GameExtensionClient` and the payload, in the `EXTENSIONS` greeting | `authentication-failed` |

The bridge never checks the game's version number. It reads `Core.getVersionNumber()` and reports it on the
state stream; the app records it with each backup and remembers it per save (`SaveGameVersionMemory`).
Extensions declare their own supported game versions ([game extensions](game-extensions.md)). What stops the
bridge on a changed game is the structural checks above: the hook's method signatures and the classes and
fields the save and observer read by reflection.

Use app, worker and bridge files from the same build.

<a id="settings"></a>
## Settings that change the request

| Setting | Effect on the request |
| --- | --- |
| **Save game before backup** off | Manual and wall-clock backups send nothing. Guarded backups send `PROBE_ACTIVE`, so the game still checks the ticket (due, not paused, same world) without saving. |
| **In-game save countdown** off | The notice language is `off`; the game shows no notices |

Both are read by the backup worker when it starts, so a backup already running keeps the values it started
with. Where they are stored and which source wins is in [advanced settings](../reference/advanced-settings.md#which-setting-wins).

<a id="building-and-publishing"></a>
## Building and testing

Building needs a Windows x64 Java 25 JDK and the Visual Studio x64 C++ tools. The game's own trimmed Java
runtime cannot be used to build.

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build src/PzTools.Backup.Cli/PzTools.Backup.Cli.csproj -p:JdkPath="$jdk"
pwsh scripts/test-game-bridge.ps1 -JdkPath $jdk
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

- `JdkPath` wins over `JAVA_HOME`. Without either, the build uses the single `jdk-25*` under
  `artifacts/toolchains`.
- The worker build also builds the Java and native parts of the bridge and the `jlink` runtime
  ([`PzTools.GameBridge.Agent.proj`](../../src/PzTools.GameBridge.Agent/PzTools.GameBridge.Agent.proj),
  [`build/GameBridgePayload.targets`](../../build/GameBridgePayload.targets)). Game jars are not needed to
  build and are never distributed.
- Bridge output goes to `artifacts/game-bridge/<Configuration>`. If a running game still holds an older native
  DLL there, choose another folder with `GameBridgeDirectory` (MSBuild) or `GameBridgeOutput` (publishing
  scripts). Keep build output apart from an installed app.

The bridge tests run against a synthetic Java program that imitates the game.
`GameSaveClient.RequestAsync(pid, savePath, save: false)` runs the connection and world checks without
saving. Tests against the real game need a throwaway world and are kept apart from the automated tests.
