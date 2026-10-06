# Startup loader

[Documentation index](../README.md)

> **Built, hidden.** The install and uninstall
> ([`StartupInstall`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/StartupInstall.java),
> [`StartupLoader`](../../src/PzTools.App.Core/StartupLoader.cs)), the loader in the game's jar, the
> delayed endpoint, a switch on the game extensions page and the
> [resident extensions](#resident-extensions)
> ([`ResidentExtensions`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/ResidentExtensions.java)).
> It shows only with `[experimental] startup_loader = true` in the app's advanced settings
> (`%LOCALAPPDATA%\PzTools\config\app\default.toml`); the shipped file does not list it. Not built:
> extensions that declare they need the install.

Today the game runs PZ Tools code only while the app is attached: the app's helper attaches after
the game has started ([game bridge](game-bridge.md#getting-into-the-game)), and the game revokes
every extension when the app's lease lapses ([game extensions](game-extensions.md)). The startup
loader is an optional install that makes the game load the same bootstrap by itself as it starts,
so extensions run whether or not the app is open. Two needs drive it:

- **Extensions that must not stop with the app.** Building power and plumbing (planned on top of a
  zone-manager extension) cut a base's fridges and water when they stop. Starting the game without
  the app, or closing the app, must not do that.
- **The coming restriction on agents loaded into a running JVM.** Java prints a warning today and
  says it will refuse such loads by default in a future release. The external attach the app uses
  is refused under that rule; the in-process load below was not (see [measured](#measured)).

## How it works

Installing patches one guarded call into the game's own jar. The call loads a small loader, which
loads the existing bootstrap from inside the game. From there everything is the path that exists
today.

1. **Install** copies `projectzomboid.jar`, inserts at the start of
   `zombie.gameStates.MainScreenState.main(String[])` one static call to the loader, wrapped in a
   handler that catches `Throwable` and does nothing, and replaces the game's jar with the result.
2. **At game start** the call runs before any game code. The loader is a native library: it loads
   the game JRE's `jli.dll` (as `pztools-attach-bootstrap.dll` does today), then `instrument.dll`
   from the same `bin` folder, and calls its `Agent_OnAttach` on the current thread with the
   bootstrap jar and the option `BOOTSTRAP1:<base64 payload path>`, the same one the helper passes
   ([`AttachMain`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/AttachMain.java)).
3. **The bootstrap** (`AgentEntry.agentmain`) gets its `Instrumentation` exactly as after an attach.
   In installed mode it also adds the [extension API](extension-api.md)'s hook to `LuaManager.init()`
   before the game loads its Lua, loads the payload once the game loads `GameWindow`, and the payload's
   [resident controller](#resident-extensions) runs the extensions the app last asked for, without
   waiting for the app.
4. **When the app starts later**, its helper attaches, finds `pztools.bridge.control.v1` already set,
   skips loading anything and connects. `AgentEntry` refuses a second load, so a reuse is the only
   path that can succeed.

The patch never contains feature code. Hooks into the game (the game loop, vehicles, power, water)
are installed at run time through `Instrumentation`, as they are today, so a new feature never
changes the patch.

### What the guarded call must survive

The call is inside a `try` that catches `Throwable`, and the loader itself catches everything. A
missing loader, a missing DLL, a load that fails or a bootstrap that throws leaves the game to start
as vanilla. A missing class at the call site is a `NoClassDefFoundError` thrown inside the `try`,
so it is caught too. This is the reason for patching the jar rather than adding `-javaagent`: the
JVM refuses to start when a `-javaagent` file is missing.

Measured on 6 October 2026 with the game's JRE, on a small class patched the same way:

| Case | Result |
| --- | --- |
| No loader class | `main` ran; nothing printed |
| Loader class whose static initialiser throws | `main` ran; nothing printed |
| Loader present, its settings missing | `main` ran; nothing printed |
| Loader present, its DLL missing | `main` ran; the loader logged `UnsatisfiedLinkError` |
| DLL present, bootstrap jar missing | `main` ran; `Agent_OnAttach` returned 100 and the JRE printed `Error opening zip file or JAR manifest missing` to standard error |
| Bootstrap present, `agentmain` throws | `main` ran; `Agent_OnAttach` returned 102 and the JRE printed the exception to standard error |

The loader therefore checks that the bootstrap jar exists and has the recorded digest before it
calls `Agent_OnAttach`, so a broken install leaves one line in the loader's own log rather than
JRE errors.

## Install, uninstall and the extension switches

The install is separate from each extension's switch.

| Control | Changes | When |
| --- | --- | --- |
| **Install** | The game's jar (patched), the [install folder](#files) | Only while no game runs |
| **Uninstall** | The game's jar (original back), the install folder (removed) | Only while no game runs |
| An extension's switch | The [resident request](#files); the running game, if the app is connected | Any time |

- **No game running.** `GameProcessFinder` already finds the launcher, a game started by `java`
  from a script, and several games. Install and uninstall are disabled while it finds any, with a
  line under the buttons saying why. A dedicated server (`zombie.network.GameServer`) uses the same
  jar but never runs `MainScreenState`; it is not found by the finder, so the
  [replace](#replacing-the-jar) handles it.
- **Not installed** is today's behaviour: extensions run while the app is attached, under the
  lease.
- **Installed** adds the start without the app and the [resident](#resident-extensions) rules.
- An extension that harms the save when it stops (building power and plumbing) declares that it
  needs the install. Its switch is disabled until the loader is installed. The vehicle extension
  does not need it: when it stops, driving falls back to vanilla.

### Replacing the jar

1. Read the game's jar and check that `MainScreenState.main(String[])` exists exactly once. If not,
   the install is refused as unsupported for this game version.
2. Write the patched jar to a temporary file beside the game's jar.
3. Copy the original to the install folder, with its SHA-256 and the game version, unless a copy of
   that exact file is already there.
4. Move the temporary file over the game's jar. A game or server that opened the jar in the
   meantime holds it, so the move fails; the original stays, nothing else changed, and the install
   reports that the game is running.
5. Record the patched jar's SHA-256.

The jar is about 65 MB, so an install takes seconds, not milliseconds; it runs as an operation with
a card, not on the UI thread.

Uninstall moves the saved original back when the game's jar is still the patched one (same
SHA-256). When the game's jar is something else, a game update has already replaced it, so
uninstall leaves it alone and only removes the install folder.

### After a game update

A game update or Steam's file check replaces the jar, which removes the patch. This is the safe
direction: the game starts as vanilla, never with an old copy of a class. The app then sees that the
jar no longer has the recorded SHA-256 and shows a card like the one for
[game memory](game-memory.md#after-a-game-update): the loader was removed by the update, with a
button to install it again. Until then, extensions run only while the app is attached.

## Files

All installed files live outside the app folder. A release extracts to a new versioned folder and
the old one is deleted later, so a path into the app folder would break at the next update.

| File | Content |
| --- | --- |
| Install folder | `%ProgramData%\PzTools\startup\s-<account digest>`, one per user: only the player's account and the administrators may change it |
| `bridge-<digest>\` | Copies of the bootstrap jar, the payload, the native loader (`pztools-attach-bootstrap.dll`) and the app's `extensions` folder (the extension runtime, the modules, the catalogue), named by content digest |
| `current` | Which `bridge-<digest>` the next game start loads, with the bootstrap's SHA-256 |
| `resident.tsv` | The [resident request](#resident-extensions): the settings revision and each continuous module, on or off, with its configuration as the app would send it in `APPLY` |
| `install.tsv` | The game's jar, its SHA-256 before the install and the patched jar's |
| `original.jar` | The game's jar as it was before the install |
| `startup.log` | One line from the loader per game start: what it loaded, or why it did not |

The patched jar holds the install folder's path. The app rewrites `current` and `resident.tsv`; it
never rewrites the game's jar to point somewhere new. The status the install tool reports names the
folder, so the app writes `resident.tsv` without working out the path itself.

The app brings the copied bridge up to its own once per run, and only while no game runs: a game
keeps running the extensions from the copy it started with, and a refresh removes older copies.

## Resident extensions

In installed mode, extensions stay in the game until it exits.

- **The request.** While installed, the app writes `resident.tsv` to the install folder whenever it
  changes: every two seconds it builds it from the extension settings, the deployed catalogue and
  the tuning files, the same way the app builds an `APPLY`, and writes it only when it differs. A
  module whose tuning file cannot be read is left out, so the game keeps what it runs.
- **The resident controller.** The payload's `ResidentExtensions` holds the lifecycle slot when no
  app is connected. Once a second it reads `resident.tsv` and, in a loaded local world, asks for each
  module that is on and not already running at that revision in that world, and turns off each one
  that is off. It goes through the same `ExtensionControl.Session` as the app, so the game checks
  both alike. Its session has no lease.
- **Handing over.** An app's connection pauses the resident controller and takes the slot. When that
  connection ends, or its lease lapses, the modules keep running and the resident controller takes
  the slot back. Neither side turns modules off on the hand-over. A payload reload asks the
  resident controller to let go too; the new payload starts its own.
- **World changes.** Leaving a world withdraws the modules as today. In the next world the resident
  controller asks for them again.
- **Faults.** A request the game refused, or a module it faulted, is not asked for again in the same
  world at the same revision; a module that needs a restart is left alone. When the app connects, it
  records the failure as it does now (`enabled: false` at that revision), which reaches
  `resident.tsv` in turn.
- **Turning off.** An extension's switch while the app is connected turns it off at once. With the
  app running but not connected (the game at the main menu, say), the next world follows the new
  request. With no app, nothing changes until the app runs again.
- **Revisions.** The resident request carries the settings revision the app uses, so a module the
  resident controller applied is already at the app's revision when the app connects, and the app's
  reconciliation finds nothing to do.
- **Not installed.** Nothing changes: the lease and the revoke on disconnect stay.

Whether resident becomes the rule for both modes is decided after the installed mode has been in
use.

## The control secret and the game's log

At startup the game writes every system property to `console.txt`. A bootstrap loaded at that
point publishes `pztools.bridge.control.v1` (`2:<pid>:<port>:<secret>`) before the list is written,
so the secret ends up in the log; in the measured run the line was cut short, but its first 23 hex
digits were there. Players post `console.txt` when they report bugs.

The secret must not reach the log. The bootstrap in installed mode publishes the property only
when the game loads `GameWindow`, which `main` first uses after writing its property list, and the
helper waits for it (stage `bootstrap-starting`, up to 15 seconds). The secret's role is unchanged: anyone who
can attach can read it anyway ([game bridge](game-bridge.md#getting-into-the-game)).

## Agents loaded into a running JVM

Java 21 and later warn when an agent is loaded into a running JVM and say a later release will
refuse it unless the JVM is started with `-XX:+EnableDynamicAgentLoading`. The game runs its own
JRE (`jre64`), so this matters only when the game ships a Java that refuses by default.

<a id="measured"></a>
Measured on 6 October 2026 with the game's JRE (Azul Zulu 25.0.1), started with
`-XX:-EnableDynamicAgentLoading` to act as that future default:

| Load | Result |
| --- | --- |
| External attach (`VirtualMachine.loadAgent`), today's helper | Refused: `Dynamic agent loading is not enabled` |
| In-process call to `instrument`'s `Agent_OnAttach`, the startup loader | Loaded; `retransformClasses` worked; no warning printed |

The in-process path is not checked today. That is the JDK's current behaviour, not a promise.

The fallbacks, in order:

1. **In-process load** (this page): needs nothing from the launcher.
2. **`-XX:+EnableDynamicAgentLoading` in `ProjectZomboid64.json`**: the supported opt-in. It keeps
   both the attach and the in-process load working. A missing file cannot stop the game, unlike
   `-javaagent`. It is written by the same `vmArgs` editor as [game memory](game-memory.md), which
   must then treat both as its own and keep both when it writes **Game default**. A game started
   from a script reads nothing from that file.
3. **Hooks patched into the jar**: needs no `Instrumentation` at all, but every feature changes the
   patch.

## Release stages

| Stage | What players see |
| --- | --- |
| Hidden | Nothing. A hidden advanced setting turns the install on for testing; hotfix releases ship from `main` with it off. |
| Recommended | **Install** on the game extensions page, marked experimental. Extensions that need it say so. |
| Default refused | If the game's Java refuses agents by default and the in-process load is refused too, the app adds fallback 2. |

The app keeps the external attach in every stage. It covers a game that is not installed, a game
whose patch an update removed, and a game started from a script with its own class path.

## Measured end to end

On 6 October 2026, without changing any game or app file, a copy of `MainScreenState` with the
guarded call was put first on the class path (as a launch script does), and the game was started
with the options of `ProjectZomboid64.json`:

1. The loader ran 0.09 seconds after `main` started. `Agent_OnAttach` returned 0, the bootstrap
   published API 11 and its control endpoint, and the game reached the main menu.
2. PZ Tools 0.2.4 was started afterwards. Its helper connected to that bootstrap, and the vehicle
   extension went from `Pending` / `connecting` to `Active` in five seconds after the world loaded.

The same day, through the app's switch on the real game folder (Build 42, started from Steam):
the install patched the jar, the game logged `pztools.bridge.bootstrap.api` but no endpoint in
`console.txt`, the app connected a second after the game started and the vehicle extension became
`Active`. The uninstall put back a jar with the original's SHA-256 and removed the install folder.

On 7 October 2026, the resident extensions on the real game, read with `jcmd` (threads and live
objects) while the app was closed:

1. Started from Steam with the app closed, the game loaded the bridge, started the resident
   controller and, in the world, applied the vehicle extension: one generation, activated, with one
   `APPLY` sent.
2. The app was opened in that world and closed again. The same generation was still running, under
   a new resident session that sent no `APPLY`: the app took the module over and handed it back
   without turning it off.
3. Back to the main menu and into a world again, still without the app, the resident controller
   sent one `APPLY` and the module ran in the new world.

Not tested yet:

- the real game starting with the guarded call and no loader files (the cases above used a small
  class patched the same way);
- whether a patched jar is refused when joining a multiplayer server.

## Alternatives rejected

| Way | Why not |
| --- | --- |
| `-javaagent` in `ProjectZomboid64.json` | The JVM does not start when the file is missing, so a deleted or moved app folder stops the game. A game started from a script is not covered. |
| A patched class file in the game folder | The class path starts with `./`, so a class there wins over the jar. A game update replaces the jar but leaves the file, and the old class then runs inside the new game. |
| Feature hooks patched into the jar | Every new feature and every game update would need a new patch. |
| Starting the game through the app | A game started from Steam or a script would get nothing. |
| A separate code path for installed mode | The bootstrap, the extension host and the fault handling would exist twice. Only the entry differs; everything after it is shared. |

## Open questions

- What the install shows when the game's jar does not have `MainScreenState.main` exactly once.
- Whether multiplayer joining checks the jar. If it does, the install must say so before it runs.
- How a player who deleted the app restores the jar: Steam's file check works; the guide should
  say so.
