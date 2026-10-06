# Startup loader (planned)

[Documentation index](../README.md)

> **Planned, not built.** This page is the design agreed before implementation. Nothing on it exists
> in the code yet. When the code lands, this page becomes its design page and the facts are checked
> against the code like any other.

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
   In installed mode it also starts the extension host from the
   [desired state](#files) without waiting for the app.
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
| An extension's switch | The desired state file; the running game, if the app is connected | Any time |

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
| Install folder | One folder per user, chosen like the attach copies for non-ASCII paths ([game bridge](game-bridge.md#folders-with-letters-outside-ascii)): only the player's account and the administrators may change it |
| `loader-<digest>.dll` | The native loader |
| `bridge-<digest>\` | Copies of the bootstrap jar, the payload and the extension runtime and modules, by content digest so a running game keeps its open files while the app writes a newer set |
| `current` | Which `bridge-<digest>` the next game start loads |
| Desired state | Which extensions are on, at which revision, with their flat configuration: what the app would send in `APPLY` |
| `original.jar` | The game's jar as it was before the install, with its SHA-256 and game version |

The patched call names the loader by a fixed path inside the install folder. The app rewrites
`current` and the desired state; it never rewrites the game's jar to point somewhere new.

## Resident extensions

In installed mode, extensions stay in the game until it exits.

- **No lease.** The 5-second lease does not revoke anything. The app's connection is used for
  control and status only.
- **World changes.** The host keeps the last desired state and activates it again in the next local
  world, without the app.
- **Faults.** A faulting module is revoked alone, as today. With no app connected, the game keeps the
  fault and the failed revision; when the app connects, it records the failure as it does now
  (`enabled: false` at that revision).
- **Turning off.** An extension's switch while the app is connected turns it off at once. With no
  app, only a game restart with an updated desired state does.
- **Not installed.** Nothing changes: the lease and the revoke on disconnect stay.

Whether resident becomes the rule for both modes is decided after the installed mode has been in
use.

## The control secret and the game's log

At startup the game writes every system property to `console.txt`. A bootstrap loaded at that
point publishes `pztools.bridge.control.v1` (`2:<pid>:<port>:<secret>`) before the list is written,
so the secret ends up in the log; in the measured run the line was cut short, but its first 23 hex
digits were there. Players post `console.txt` when they report bugs.

The secret must not reach the log. The bootstrap in installed mode publishes the property only
after the game has written its property list (the first game-loop tick is the candidate), and the
helper waits for it as it already waits for a connection. The secret's role is unchanged: anyone who
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

Not tested yet:

- the real game starting with the guarded call and no loader files (the cases above used a small
  class patched the same way);
- whether a patched jar is refused when joining a multiplayer server;
- an install and uninstall against the real jar.

## Alternatives rejected

| Way | Why not |
| --- | --- |
| `-javaagent` in `ProjectZomboid64.json` | The JVM does not start when the file is missing, so a deleted or moved app folder stops the game. A game started from a script is not covered. |
| A patched class file in the game folder | The class path starts with `./`, so a class there wins over the jar. A game update replaces the jar but leaves the file, and the old class then runs inside the new game. |
| Feature hooks patched into the jar | Every new feature and every game update would need a new patch. |
| Starting the game through the app | A game started from Steam or a script would get nothing. |
| A separate code path for installed mode | The bootstrap, the extension host and the fault handling would exist twice. Only the entry differs; everything after it is shared. |

## Open questions

- The name and place of the hidden setting.
- Where installed mode publishes the control property, if not the first game-loop tick.
- What the install shows when the game's jar does not have `MainScreenState.main` exactly once.
- Whether multiplayer joining checks the jar. If it does, the install must say so before it runs.
- How a player who deleted the app restores the jar: Steam's file check works; the guide should
  say so.
