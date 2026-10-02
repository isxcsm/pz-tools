# Saving the game before a backup

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

Project Zomboid keeps recent changes in memory and writes them to disk only when it
saves. A backup made from the files alone can therefore miss the last few minutes of
play. To avoid that, PZ Tools can ask the running game to save just before a backup
starts copying files.

The save is the game's own: the same one it makes when you save from the menu. The
game may pause briefly while it saves, as it always does. Nothing has to be installed
for this: no Workshop mod, no launch option, and no change to game files.

The part of PZ Tools that talks to the game is the **game bridge**. Besides saving,
it streams the game's state (pause, sleep, character death), hosts the optional
[game extensions](game-extensions.md) and records [performance profiles](profiler.md).
The [overview](overview.md) shows where it sits.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| **Save game before backup** | On | Asks the game to save before each backup. Off: only what is already on disk is backed up. |
| **In-game save countdown** | On | Before an automatic backup saves the game, shows notices above your character: a countdown, then *saving*, then done or failed. A backup started from the app saves at once, without notices. |

Both apply from the next backup; one already running keeps the settings it started
with. Neither affects game-state monitoring or the game extensions. The same choices
exist as `save_game_before_backup` and `game_save_countdown` in the
[backup worker settings](configuration.md); where both are set, the app's choice wins,
and a command-line option wins over both. On the command line, game backups use
`--save-game`.

**A finished game save is not a finished backup.** Copying and compressing the files
comes afterwards, and the app's progress card shows when the backup itself is done.

## What happens during a backup

1. The backup worker takes the repository's [writer lock](glossary.md#writer-lock), so
   no other job can change the backup folder meanwhile.
2. It connects to the game bridge in the game, loading it first if this is the first
   request since the game started.
3. The bridge checks that the request fits the game: the right game process, a loaded
   world, the save that is to be backed up, and, for a periodic backup, that the game
   is not paused and that the backup is really due (see [admission](glossary.md#admission)).
4. If notices are on, the countdown is shown. A periodic backup starts preparing
   about eight seconds before it is due and shows only the last five seconds; a
   manual backup counts down five seconds first.
5. The game saves on its own thread. The *saving* notice appears when the request is
   accepted and is followed by *done* or *failed*.
6. Only after the game's save call has returned does the worker start looking for
   changed files and copying them.

<a id="admission-and-failures"></a>
## When the game is not saved

Whether a backup still goes ahead depends on why the save did not happen, and on
whether the backup is manual or automatic.

| Situation | Manual backup | Automatic backup |
| --- | --- | --- |
| The save is confirmed not in use | Backs up the files; the game is not contacted | Not made: automatic backups need active play |
| No game running, no world loaded, or a different save loaded | Backs up the files on disk | Skipped |
| The bridge cannot be reached (helper cannot start or attach, connection times out, bridge missing or too old) | Backs up the files on disk and records a warning | Same: backs up the files on disk with a warning |
| Game-aware timing says not now (paused, asleep, not yet due) | — | Postponed; it keeps its place in the schedule and no backup is recorded |
| The game refuses, reports failure, or never answers after the request was sent | No backup | No backup, and it is not retried automatically |
| The game build is not supported, or it is unclear which save is meant | No backup | No backup |

The difference between the third row and the last two: when the bridge cannot be
reached, nothing was asked of the game, so the files on disk are what there is. Once
the game has been asked, an unclear answer is not treated as permission to copy.
Death backups follow the same rules; see [game-aware timing](runtime-pause-backups.md#when-the-game-cannot-be-read).

With **Save game before backup** off, a game-aware periodic backup still asks the
game whether it is due and not paused; it just does not save.

A few more rules:

- A request waiting in the game's queue gives up after 15 seconds by default.
- Cancelling, or losing the connection, can stop a request that is still queued or
  counting down. It cannot stop a save the game has already started; PZ Tools waits
  for that save to return before letting anything else use the game.
- A notice that fails to show, or a failed [character recovery stamp](character-recovery.md),
  is reported on its own and does not cancel an otherwise good save.

## Limits

- **Single player, Build 42, Java 25 only.** Multiplayer, game modes without saving,
  and worlds other than the one being backed up are refused.
- **Game updates can break it.** The bridge relies on how the inspected Build 42 game
  is built. An update, a modified game file or another Java agent can make it refuse
  to save until PZ Tools is updated. It refuses rather than guessing.
- **Not an instant snapshot.** The game's save and PZ Tools' per-file checks do not
  add up to a single frozen moment of the whole world, and they do not force data out
  of disk caches onto the hardware.
- **Not to the second.** Paused frames, the time to attach and a busy disk can delay a
  save beyond its deadline. Turning notices off does not make periodic backups run
  earlier.

See [game-aware timing](runtime-pause-backups.md) for how periodic timing works and
[character recovery](character-recovery.md) for the identity stamp, written while the
game is watched and again before saving.

## How it works inside

### Getting into the game

A small native helper uses the game's own Java launcher library (`jli.dll`) and Java's
standard attach mechanism to load the bridge into the running game. PZ Tools' own
bundled Java runtime is never loaded into the game. There is no remote-thread
injection, and no fallback that edits game files.

The game's Java misreads a path with letters outside ASCII for the two files handed to it
by path at attach, the native helper and the bootstrap. With the app in such a folder
(a Korean folder name was reported), those two are copied once, by their content, to
`%ProgramData%\PzTools\attach\` and handed over from there; everything else is read
from the app folder as it is.

The bridge then calls the game's original `GameWindow.save(true)` on the game thread.

### Layers

The bridge is loaded once per game session and reused for every request. It has
three layers, so that most of it can be updated without restarting the game (see
[component updates](module-reload.md)):

| Layer | What it holds | Replaced while the game runs? |
| --- | --- | --- |
| [Bootstrap](glossary.md#bootstrap) | An authenticated listener on the local machine only, and a minimal hook in the game loop | No |
| [Payload](glossary.md#payload) | Saving, the state stream, extension control, profiling | Yes, at an idle moment |
| [Extension runtime](glossary.md#extension-runtime-host) and modules | Game extensions | Yes, each on its own |

State streaming, saving, extension control and profiling share the listener, but each
has its own connection and its own rules for who may do what. The listener accepts a
fixed set of commands from PZ Tools; it does not run Lua or Java code sent to it.

<a id="compatibility-and-lifecycle"></a>
### Compatibility between PZ Tools and the bridge in the game

The bridge stays in the game after PZ Tools closes, so a newer PZ Tools may meet a
bridge from an older version. These version numbers decide what happens. This table
is the one place they are recorded; other pages link here.

| Contract | Current | Checked between | On a mismatch |
| --- | --- | --- | --- |
| Bootstrap API | 11 | The bootstrap in the game and the payload | The app says to restart the game, once. Bootstraps of API 10 or earlier (PZ Tools 0.2.1 and before) need this. |
| Save protocol | 6 | The backup worker and the payload (`HELLO` line) | `unsupported-protocol`: nothing is asked of the game and the backup uses the files on disk, as in the table above |
| Extension host ABI | 3 | The extension runtime and each module archive | The module is not loaded |
| Extension control wire | 1 | Not checked on connection; the number labels the command format | Both sides come from the same build, and the payload in the game is replaced to match |
| State stream (WATCH) | `STATE4` | The state scheduler and the state stream | The frame is rejected; older `STATE1`–`STATE3` are still read |

A compatible update of the payload or a module is picked up at an idle moment,
including after the app has been moved to another folder. Use app and worker files
from the same build.

A change the bootstrap must know about raises the bootstrap API rather than keeping old
names alive in the payload: the attach helper reads the API of the bootstrap already in
the game before sending anything, and on a mismatch the app asks for one restart of the
game. API 11 came with the bridge's rename from the save bridge: the bootstrap now loads
each request's entry as `BridgeSession`.

### Code

| Component | Responsibility |
| --- | --- |
| `PzTools.GameBridge` | Finding the game, authenticated requests, deadlines, reading results |
| `PzTools.Zomboid.Backup` | Deciding whether and how to prepare a backup (the table above) |
| `PzTools.GameBridge.Agent` | Attach entry point, game adapter, code that runs in the game |
| `PzTools.GameBridge.Native` | Windows native bootstrap (JVMTI) |
| `build/GameBridgePayload.targets` | Build and deployment integration |

The general backup engine knows nothing about the game: it receives a preparation
step to run before capture. The game extensions use a separate control connection
and never replace the save call.

<a id="building-and-publishing"></a>
## Building and testing

Building needs a Windows x64 Java 25 JDK and the Visual Studio x64 C++ tools. The
game's own trimmed Java runtime cannot be used to build.

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build src/PzTools.Backup.Cli/PzTools.Backup.Cli.csproj -p:JdkPath="$jdk"
pwsh scripts/test-game-bridge.ps1 -JdkPath $jdk
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

- `JdkPath` wins over `JAVA_HOME`. Without either, the build uses the single Java 25
  JDK under `artifacts/toolchains`.
- The normal worker build also produces the Java and native parts of the bridge and a
  reduced Java runtime for attaching. Game JARs are not needed to build and are never
  distributed.
- Bridge output goes to `artifacts/game-bridge/<Configuration>`. If a running game
  still holds an older native DLL there, choose another folder with
  `GameBridgeDirectory` (MSBuild) or `GameBridgeOutput` (publishing scripts). Keep
  build output apart from an installed app.

The bridge tests run against a synthetic Java program that imitates the game.
`GameSaveClient.RequestAsync(pid, savePath, save: false)` performs the connection and
world checks without saving. Tests against the real game need a throwaway world and
are kept apart from the automated tests.
