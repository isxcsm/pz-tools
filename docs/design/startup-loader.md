# Startup loader

[Documentation index](../README.md)

> **Built, hidden.** The install and uninstall
> ([`StartupInstall`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/StartupInstall.java),
> [`StartupLoader`](../../src/PzTools.App.Core/StartupLoader.cs)), the entry in the game's folder
> ([`BootProvider`](../../src/PzTools.GameBridge.Agent/java/pztools/startup/BootProvider.java)), the
> delayed endpoint, a switch on the game extensions page, the
> [resident extensions](#resident-extensions)
> ([`ResidentExtensions`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/ResidentExtensions.java))
> and the extension API's own runner
> ([`ResidentApi`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/ResidentApi.java)).
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

No game file changes. The game's launcher puts the game's folder (`.`) first on the class path, and
the install adds four files of PZ Tools' own there. They make the JDK start a small loader early in
the game's `main`, which loads the existing bootstrap from inside the game. From there everything
is the path that exists today.

1. **Install** writes, in the game's folder:
   - `pztools/startup/StartupLoader.class` and `pztools/startup/BootProvider.class`;
   - `pztools/startup/install.properties`, the install folder's path;
   - a line `pztools.startup.BootProvider` in `META-INF/services/java.nio.file.spi.FileSystemProvider`,
     beside any lines of other tools.
2. **At game start** the JDK lists the installed file system providers the first time anything
   asks for one, and creates each provider named in a services file on the class path. The game
   asks early in `MainScreenState.main`, when it zips its last logs (`ZipLogs.addZipFile`, right
   after reading its arguments, before its property list). Creating `BootProvider` starts the
   loader. The provider serves no files; its scheme, `pztools-startup`, is its own.
3. **The loader** is a native library: it loads the game JRE's `jli.dll` (as
   `pztools-attach-bootstrap.dll` does today), then `instrument.dll` from the same `bin` folder, and
   calls its `Agent_OnAttach` on the current thread with the bootstrap jar and the option
   `BOOTSTRAP1:<base64 payload path>`, the same one the helper passes
   ([`AttachMain`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/AttachMain.java)).
4. **The bootstrap** (`AgentEntry.agentmain`) gets its `Instrumentation` exactly as after an attach.
   In installed mode it also adds the [extension API](extension-api.md)'s hooks, to `LuaManager.init()`
   before the game loads its Lua and to the game's power and water questions. Once the game loads
   `GameWindow` it loads the payload and runs the payload's startup (`PayloadEntry`, kind `STARTUP`),
   once per payload: the extension API starts (`ResidentApi`), and the payload's
   [resident controller](#resident-extensions) runs the extensions the app last asked for, without
   waiting for the app.
5. **When the app starts later**, its helper attaches, finds `pztools.bridge.control.v1` already set,
   skips loading anything and connects. `AgentEntry` refuses a second load, so a reuse is the only
   path that can succeed.

The entry never contains feature code. Hooks into the game (the game loop, vehicles, power, water)
are installed at run time through `Instrumentation`, as they are today, so a new feature never
changes the entry.

### Why not a changed game class

Earlier versions patched the same call into `MainScreenState.main` inside the game's jar. That
worked alone, but other mods check the game's classes against the ones they were built for.
PZ Optimize (loose class files that replace about 130 game classes, `MainScreenState` among them)
compares the SHA-256 of each class it replaces with the stock one at every start; on 7 October 2026
it took the patched `MainScreenState` for a game update, removed all of its 1064 files and restarted
the game without them. Such mods update several times a day, and the set of classes they replace
changes with them, so no game class is safe to change. The entry adds files of its own and changes
none of the game's.

An install from an earlier version is turned into this one by the next install or refresh, which put
the game's own jar back from the copy the install kept.

### What the entry must survive

The JDK creates the providers inside its own lock, with a flag that marks the list as loading. A
provider that cannot be created (`ServiceConfigurationError`) leaves the flag set, and every later
request for a provider, the game's log zip included, fails for the rest of the run. So:

- `BootProvider` uses `java.base` alone and catches everything in its constructor. A missing or
  broken `StartupLoader` is a `NoClassDefFoundError` inside that `try`.
- The install writes the classes before the service line, and uninstall removes the line before the
  classes, so the line never names a class that is not there.
- Neither the loader nor the bootstrap asks for a file system provider while it runs (the JDK would
  call that circular), and neither waits for another thread that might.
- `StartupLoader.start` runs once per process, however many times something lists the providers.

The loader itself catches everything. A missing DLL, a load that fails or a bootstrap that throws
leaves the game to start as vanilla. Measured on 6 October 2026 with the game's JRE, on a small
class calling the loader the same guarded way:

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
JRE errors. The startup loader test starts its synthetic game, which zips a file first as the game
does, after each change to the install, a broken one included.

## Install, uninstall and the extension switches

The install is separate from each extension's switch.

| Control | Changes | When |
| --- | --- | --- |
| **Install** | The [entry](#how-it-works) in the game's folder, the [install folder](#files) | Only while no game runs |
| **Uninstall** | The entry (removed; other tools' service lines stay), the install folder (removed) | Only while no game runs |
| An extension's switch | The [resident request](#files); the running game, if the app is connected | Any time |

- **No game running.** `GameProcessFinder` already finds the launcher, a game started by `java`
  from a script, and several games. Install and uninstall are disabled while it finds any, with a
  line under the buttons saying why: a game started mid-install would find half of one, and turning
  an earlier version's install into this kind puts back a jar a running game holds. The app's
  `StartupLoader` does this look, the install tool's runs and its file reads on the thread pool,
  never on the UI thread that calls it.
- **Not installed** is today's behaviour: extensions run while the app is attached, under the
  lease.
- **Installed** adds the start without the app and the [resident](#resident-extensions) rules.
- An extension that harms the save when it stops (building power and plumbing) declares that it
  needs the install. Its switch is disabled until the loader is installed. The vehicle extension
  does not need it: when it stops, driving falls back to vanilla.

### States

| State | Means |
| --- | --- |
| Installed | The install folder's record, and the whole entry in the game's folder naming that install folder |
| Not installed | No record. An entry left in the game's folder by an install whose folder was deleted is still this install's own: install takes it over and uninstall removes it. |
| Reverted | A record, and part of the entry is gone from the game's folder. Install again. |
| Foreign | A loader patched into the game's jar with no record: an earlier version's whose record is gone, or another tool's. Install and uninstall refuse it; Steam's file check restores the jar. |

### The game that runs

Installed says what the next game start loads. While one game runs, the app also reads how it went
in that game, from the install folder (`StartupLoader.ReadGame`), and the startup loader's card says
when it did not go well; each new finding also goes to the log once, as a warning:

| Finding | From |
| --- | --- |
| Started without the loader | `startup.log` is older than the game process: the game started before the entry was in its folder, or did not run it |
| Did not load | `startup.log` is this run's and says why (a missing file, a bootstrap that does not match) |
| Hooks missing | `api.tsv` names this process and some of the [extension API's hooks](extension-api.md#how-the-game-is-answered) did not go in, with why |

The app reads them on its own rounds (every two minutes) and when the page opens, not as they
happen: most hooks go in as the first world loads.

### After a game update

A game update or Steam's file check replaces the game's own files and leaves files it does not know,
so the entry stays and the game keeps loading PZ Tools. The entry holds no game code: it runs the
same in a new game version. The hooks the bootstrap installs check the game's classes as they load
and give vanilla's answer where a method is not shaped as expected, one hook at a time; the app
says which ([The game that runs](#the-game-that-runs)).

## Files

All installed files live outside the app folder. A release extracts to a new versioned folder and
the old one is deleted later, so a path into the app folder would break at the next update.

| File | Content |
| --- | --- |
| Install folder | `%ProgramData%\PzTools\startup\s-<account digest>`, one per user: only the player's account and the administrators may change it |
| `bridge-<digest>\` | Copies of the bootstrap jar, the payload, the native loader (`pztools-attach-bootstrap.dll`) and the app's `extensions` folder (the extension runtime, the modules, the catalogue), named by content digest |
| `current` | Which `bridge-<digest>` the next game start loads, with the bootstrap's SHA-256 |
| `resident.tsv` | The [resident request](#resident-extensions): the settings revision and each continuous module, on or off, with its configuration as the app would send it in `APPLY` |
| `install.tsv` | The game's folder and the entry's SHA-256 (while an earlier version's jar patch is still in place: the jar's SHA-256 before and after it) |
| `original.jar` | Only while an earlier version's jar patch is in place: the game's jar as it was before it |
| `startup.log` | One line from the loader per game start: what it loaded, or why it did not |
| `api.tsv` | Written by the game: its process id, and each of the extension API's hooks, applied, not loaded yet, or why it did not go in. Rewritten when that changes. |

The entry's `install.properties` holds the install folder's path. The app rewrites `current` and
`resident.tsv`; it never rewrites the entry to point somewhere new. The status the install tool
reports names the folder, so the app writes `resident.tsv` without working out the path itself.

The app brings the copied bridge and the entry up to its own once per run, and only while no game
runs; a refresh removes older copies (one a running game holds open stays until a later refresh). A
game runs the extensions from the copy it started with, also after the app connects, as long as the
app's `extensions` folder holds the same files, which it does when the app refreshed the copy before
the game started. An app of another version connected to a running game brings its own extensions, and
the game runs them from that app's folder while that folder lasts; once an update has deleted it, the
game goes back to the copy (`ExtensionHost.directory`).

## Resident extensions

In installed mode, extensions stay in the game until it exits.

- **The request.** While installed, the app writes `resident.tsv` to the install folder whenever it
  changes. Every two seconds it compares the time and length of the files it is built from (the
  extension settings, the deployed catalogue, each extension's tuning files) and of `resident.tsv`
  itself with those of its last write. When one moved, it builds the request the same way the app
  builds an `APPLY`, and writes it only when it differs. A
  module whose configuration cannot be built (a tuning file unreadable or invalid) is written off,
  as the app turns it off while connected
  ([failure handling](game-extensions.md#failure-handling)); its saved switch stays as it is.
- **The resident controller.** The payload's `ResidentExtensions` holds the extension lifecycle (the
  frame router's lifecycle job, see [the game-loop hook](game-bridge.md#the-game-loop-hook)) when no
  app is connected. Once a second it reads `resident.tsv` and, in a loaded local world, asks for each
  module that is on and not already running at that revision in that world, and turns off each one
  that is off. It goes through the same `ExtensionControl.Session` as the app, so the game checks
  both alike. Its session has no lease.
- **Handing over.** An app's connection pauses the resident controller and takes the lifecycle. When
  that connection ends, or its lease lapses, the modules keep running and the resident controller
  takes the lifecycle back. Neither side turns modules off on the hand-over. A payload reload asks the
  resident controller to let go too; the new payload starts its own.
- **World changes.** Leaving a world withdraws the modules as today. In the next world the resident
  controller asks for them again.
- **Faults.** A request the game refused, or a module it faulted, is not asked for again in the same
  world at the same revision; a module that needs a restart is left alone. A pass of the controller
  that fails in any way (an extension runtime whose classes do not link, say) lets go of the
  lifecycle, and the next pass tries again: the controller does not stop while the game runs. When the app connects, it
  records the failure as it does now (`enabled: false` at that revision), which reaches
  `resident.tsv` in turn.
- **Turning off.** An extension's switch while the app is connected turns it off at once. With the
  app running but not connected (the game at the main menu, say), the next world follows the new
  request. With no app, nothing changes until the app runs again.
- **Revisions.** The resident request carries the settings revision the app uses, so a module the
  resident controller applied is already at the app's revision when the app connects, and the app's
  reconciliation finds nothing to do.
- **The extension API.** It does not depend on the extensions: its own thread (`ResidentApi`) holds
  the frame router's API job, which runs the API's per-frame work (setting the API into a Lua
  environment the game made before the payload loaded, and the power and water networks), and writes
  `api.tsv` once a second, with or without the app and whether or not any extension runs.
- **Not installed.** Nothing changes: the lease and the revoke on disconnect stay.

Whether resident becomes the rule for both modes is decided after the installed mode has been in
use.

## The control secret and the game's log

At startup the game writes every system property to `console.txt`. A bootstrap loaded at that
point publishes `pztools.bridge.control.v1` (`2:<pid>:<port>:<secret>`) before the list is written,
so the secret ends up in the log; in the measured run the line was cut short, but its first 23 hex
digits were there. Players post `console.txt` when they report bugs.

The secret must not reach the log. The bootstrap publishes the property only when the game loads
`GameWindow`, which `main` first uses after writing its property list, and the helper waits for it
(stage `bootstrap-starting`, up to 15 seconds). This holds however the bootstrap was loaded: by the
loader, or by the app's helper attaching to a game that has only just started. The secret's role is
unchanged: anyone who can attach can read it anyway
([game bridge](game-bridge.md#getting-into-the-game)).

### The app open as the game starts

An app that is already open finds the game's process as soon as it exists, and its helper can attach
before `main` reaches the loader. Its bootstrap is then loaded first, and the loader's
`Agent_OnAttach` reaches the same `AgentEntry` (the system class loader has it already). Until 7
October 2026 that call failed (`the bootstrap did not load (102)`), and the game ran as if the app had
attached to a vanilla game: no resident extensions, no extension API, and the secret in the log. Now
the bootstrap takes the loader's call as making the game one the loader started: it takes the
install folder, adds the extension API's hook, and starts the resident extensions once the endpoint is
set. The startup loader test covers it by loading the bootstrap before `main` with an agent that stands
in for the helper.

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
   patch, and other mods take any changed game class for a game update.

## Release stages

| Stage | What players see |
| --- | --- |
| Hidden | Nothing. A hidden advanced setting turns the install on for testing; hotfix releases ship from `main` with it off. |
| Recommended | **Install** on the game extensions page, marked experimental. Extensions that need it say so. |
| Default refused | If the game's Java refuses agents by default and the in-process load is refused too, the app adds fallback 2. |

The app keeps the external attach in every stage. It covers a game that is not installed and a game
started from a script with its own class path.

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

### Choosing the entry

On 7 October 2026 the real game (Build 42.21) was started with a measuring agent that logged every
`ServiceLoader` the JVM created, with the time since `main` started, until `LuaManager.init` (13.6
seconds after `main`). The lookups before it, through the system class loader:

| After `main` | Service | Asked by | As an entry |
| --- | --- | --- | --- |
| 0.48 s | `LocaleDataMetaInfo` | The JDK's locale data | Not read from the class path |
| 0.56 s | `FileSystemProvider` | The game's log zip (`ZipLogs.addZipFile`) | Chosen: a provider of its own scheme changes nothing else |
| 0.58 s | `ZoneRulesProvider` | Time zones | A failure ends the game (an error in a static initialiser) |
| 0.99 s | `System.LoggerFinder` | The JDK's logging | Registering one replaces the logging backend |
| 3.4–3.5 s | XML and JAXB factories, `CharsetProvider` | The game's XML files | Registering one takes over XML parsing or character sets |

PZ Optimize's own `MainScreenState` calls `ZipLogs.addZipFile` the same way.

On 8 October 2026 the game was started with its original jar and the entry on the class path: the
JDK created the provider 0.48 seconds after `main`, the loader logged `loaded bridge-…`, the game
zipped its logs as usual, and at the main menu the extension API's classes were loaded (`jcmd`) after
`LuaManager.init` 14 seconds later.

Not tested yet:

- the real game starting with the entry and no install folder (the synthetic game covers it);
- the real game with PZ Optimize installed beside the entry.

## Alternatives rejected

| Way | Why not |
| --- | --- |
| A call patched into `MainScreenState` in the game's jar | Mods that check the game's classes against stock (PZ Optimize) take the changed class for a game update and remove themselves. Used until 8 October 2026. |
| `-javaagent` in `ProjectZomboid64.json` | The JVM does not start when the file is missing, so a deleted or moved app folder stops the game. A game started from a script is not covered. |
| A patched game class file in the game folder | The class path starts with `./`, so a class there wins over the jar. A game update replaces the jar but leaves the file, and the old class then runs inside the new game. Mods that replace the same class collide with it. The entry's classes are PZ Tools' own and replace nothing. |
| Another service as the entry | See [choosing the entry](#choosing-the-entry). |
| Feature hooks patched into the jar | Every new feature and every game update would need a new patch. |
| Starting the game through the app | A game started from Steam or a script would get nothing. |
| A separate code path for installed mode | The bootstrap, the extension host and the fault handling would exist twice. Only the entry differs; everything after it is shared. |

## Open questions

- Whether multiplayer joining checks the game folder's extra files. If it does, the install must
  say so before it runs.
- A game that stops listing file system providers before Lua starts would load PZ Tools late or not
  at all; the app does not yet show that the loader did not run in a game it started.
