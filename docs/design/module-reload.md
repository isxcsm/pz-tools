# Replacing code in a running game

[Documentation index](../README.md)

PZ Tools loads Java code into the running game: the [game bridge](game-bridge.md) and the
[game extensions](game-extensions.md). When PZ Tools is updated, or moved to another folder, while the game runs,
most of that code is replaced in place on the next connection. This page covers what is replaced, when, how a
change is detected, and what survives the switch.

## Layers

| Layer | File in `game-bridge\` | Replaced while the game runs? |
| --- | --- | --- |
| Native attach bootstrap | `pztools-attach-bootstrap.dll` | No. Loaded on the first attach only. |
| [Bootstrap](glossary.md#bootstrap) | `pztools-game-bootstrap.jar`: `AgentEntry`, `ControlServer`, `GameHook`, `Payload`, `ApiHooks`, `RuntimeCharacterIdentity` and the module API of the extensions (`pztools.extensions.api`) | No. Needs a game restart. |
| [Payload](glossary.md#payload) | `pztools-game-bridge.jar`: its entry and frame router, save requests, WATCH, extension control and the loading of the extension runtime and of the extension API, the resident extensions of a startup game, profiler, notices, leases | Yes |
| [Extension API](extension-api.md) | `extensions\pztools-extension-api.jar`: `GameApi`, buildings, power and water networks (`pztools.api`); loaded only in a game the [startup loader](startup-loader.md) started | Yes |
| [Extension runtime](glossary.md#extension-runtime-host) | `extensions\pztools-extension-runtime.jar`: `ModuleHost`, `ContinuousRuntime` | Yes |
| [Modules](glossary.md#extension-module) | `extensions\pztools-vehicle-drivetrain.jar`, listed in `extensions\catalog.tsv` | Yes, each in its own [slot](glossary.md#slot) |

The packaging is in
[`PzTools.GameBridge.Agent.proj`](../../src/PzTools.GameBridge.Agent/PzTools.GameBridge.Agent.proj). The bootstrap
jar is built with fixed timestamps, so its bytes stay the same across builds that do not change it.

The bootstrap owns everything that has to outlive a replacement, and no feature
([`AgentEntry`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/AgentEntry.java) and the classes beside it):

- The control socket on 127.0.0.1 and its secret. Every connection from PZ Tools goes through it. The session kinds
  are the payload's: the bootstrap hands each to the payload's one entry (`PayloadEntry.dispatch`), so a new kind
  needs no restart ([game bridge](game-bridge.md#layers)).
- The game-loop hook: one call to `AgentEntry.poll()` added at the start of `GameWindow.logic()`. A payload puts its
  per-frame work in two callbacks instead of hooking the game again: its frame router, which runs every per-frame
  job of the payload, and the game-thread work of a save request
  ([the game-loop hook](game-bridge.md#the-game-loop-hook)).
- What a payload keeps for the next one (`AgentEntry.kept`): the extension runtime's host. The payload loads it;
  the bootstrap only holds it.
- In a game the [startup loader](startup-loader.md) started, the [extension API](extension-api.md)'s hooks: a
  call to `ApiHooks.luaStarted` added at the end of `LuaManager.init()` before the game loads its Lua, and the
  power hooks in `IsoGridSquare`, `ItemContainer`, `IsoLightSwitch`, `DeviceData`, `LightingJNI`, `Food` and
  `IsoGenerator`, and the water hooks in `IsoObject`, added as those classes load. Each payload sets the handlers that answer them, replacing the
  last one's.
- `RuntimeCharacterIdentity` (character and death ids, for WATCH).
- The extension API classes, including `RuntimeIdentity` (process and world ids) and `ControlPoints` (the
  [control points](game-extensions.md#control-points) modules' bytecode calls). Payload and module archives are
  loaded with their own copies of these packages skipped, so every generation sees the same classes.

## Compatibility checks

| Check | Where | Failure |
| --- | --- | --- |
| The game's `pztools.bridge.bootstrap.api` property is `12` | Attach helper ([`AttachMain`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/AttachMain.java)), before sending anything | "Restart the game to use the updated bridge", and nothing is sent. The state stream and extension control report `restart-required`; a save request reports `attach-failed`. |
| The payload jar's manifest has `PzTools-Bootstrap-Api: 12`, and its entry links | `Payload.prepare` (bootstrap) | `PAYLOAD_UNAVAILABLE`; the old payload stays |
| The runtime and module jars have `PzTools-Extension-Api: 3` (`ExtensionApi.HOST_ABI`) | `ExtensionHost.current` (payload, against the API classes the game loaded), `ModuleHost.resolve`, `ContinuousRuntime.apply` | The runtime or module is not loaded |

`HOST_ABI` is compiled into the resident API classes, so a runtime jar with a new extension ABI is refused and
only a restart of the game fixes it. Extension control compares the ABI this payload was built for with the
resident class's and then answers `RestartRequired` with the reason `bootstrap-update`, the state an older
bootstrap also gives: the extension stays off in this game, its switch keeps its setting, and it returns with the
next game ([`GameExtensionActivationState`](../../src/PzTools.GameBridge/GameExtensionActivationState.cs)). A runtime
jar refused for any other reason is `host-update-unavailable`, a module jar `update-rejected:IOException`. The
current version numbers are in the [compatibility table](game-bridge.md#compatibility-and-lifecycle).

A periodic backup is held while the game reports `restart-required`, because the game cannot be asked to save. A
manual backup still runs from the files on disk ([`BackupScheduler.WaitsForGameRestart`](../../src/PzTools.Scheduling/BackupScheduler.cs)).

## How a change is detected

[`ClassArchive.read`](../../src/PzTools.GameExtensions.Java/java/pztools/extensions/api/internal/ClassArchive.java)
reads an archive into memory once. The SHA-256 digest, the manifest check and class loading all use those bytes,
so a file that is rewritten mid-load cannot mix two versions. The reader limits an archive to 16 MiB, 1024 classes
and 32 MiB of class data.

| Layer | Counts as changed when |
| --- | --- |
| Payload | Its digest differs from the loaded one |
| Extension runtime | Its digest differs from the loaded one |
| Continuous module | The digest or its catalogue definition (id, version, namespace, entry class, jar, supported game versions, capability) differs, or the world, the game class loader or the generation is no longer the one loaded |

A module's title and description are not part of the definition; changing them reloads nothing. The same bytes
at a new path are not a change ([app moved](#when-the-app-is-moved)).

## When each layer is replaced

| Layer | Checked on |
| --- | --- |
| Payload | Every control connection: a save, probe, profiler or notice request, a WATCH connection, an extension-control connection |
| Extension runtime | Every extension-control `APPLY`, and the first `STATUS`, `PING` or `OFF` of a control session |
| Continuous module | Extension-control `APPLY` only |

The state scheduler sends `APPLY` for a new [settings revision](glossary.md#settings-revision), a new game process
or world, or a new control session
([`RuntimeExtensionCoordinator`](../../src/PzTools.State.Scheduler/RuntimeExtensionCoordinator.cs)). Otherwise it
sends `PING`, which reloads nothing. A backup or a WATCH connection never touches the runtime or modules.

### Payload

`Payload.prepare` (bootstrap) runs under one lock, in the bridge's control thread or, in a game the
[startup loader](startup-loader.md) started, its startup thread:

1. Read the new jar and check its bootstrap API. If the digest is unchanged, use the loaded payload.
2. If a save request is in progress, or a save still holds the game thread, answer `BUSY` at once. The save is never
   interrupted; the client tries again
   ([`GameSaveClient`](../../src/PzTools.GameBridge/GameSaveClient.cs) retries every 500 ms for up to 10 s).
3. Load the new payload and resolve its one entry, `PayloadEntry.dispatch`. A broken payload fails here (a missing
   class or a link error alike), before anything is stopped.
4. Ask the payload's sessions and threads to let go (`runtimeReloadRequested`) and pause the game-loop callbacks;
   nothing new may take them until the switch ends. WATCH, extension control, the resident controller, the
   extension API's thread, the profiler's monitor and the notes' relay check the request at least every 250 ms.
5. Wait up to 3 seconds for every session to end and every per-frame job to be let go. If they do not, answer
   `BUSY` and keep the old payload; what let go takes its work up again.
6. Switch to the new entry. In a game the startup loader started, the new payload's startup runs (its extension API
   and resident controller), then the client that asked gets the new payload's session.

The state scheduler reconnects WATCH and extension control on its own. Ending the app's extension-control session
retires every continuous module, so a payload update turns vehicle controls off until the next `APPLY` reaches a
[safe boundary](glossary.md#safe-boundary). In a game the startup loader started it does not: the modules keep
running, and the new payload's [resident controller](startup-loader.md#resident-extensions) takes them over.

| Kept in the bootstrap | Lost with the old payload |
| --- | --- |
| Process, world, character and death ids | The app runs' [leases](game-bridge.md#leases) |
| The extension runtime and its host, the extension API | Running profiler recordings and a note still waiting to be shown |
| The game-loop hook and the control socket | The last save report |
| | The continuous modules' generations (retired as above, unless the game was started by the startup loader) |

A new [observer epoch](glossary.md#observer-epoch) starts with every WATCH subscription, so also after a payload
switch. A [ticket](glossary.md#ticket) issued under the old epoch is refused with `runtime-epoch-changed`, so a
reading from before the switch cannot trigger a backup. A character already dead when WATCH reconnects is reported
as a fact, not as a new death, and the app also de-duplicates deaths by process, world, character and death id
([`RuntimeDeathPolicy`](../../src/PzTools.Scheduling/RuntimeDeathPolicy.cs)).

### Extension runtime

`ExtensionHost.current` (payload) reads the new runtime jar and constructs the new `ModuleHost` (which reads the
catalogue) before closing the old one. The host is kept by the bootstrap (`AgentEntry.kept`), so it outlives a
payload switch; which jar and folder it comes from is the payload's to know. Closing the old host retires every module and waits up to 5 seconds for its executor.
If the old host cannot be closed, the new one is discarded and the old one stays. An `APPLY` then answers
`host-update-unavailable`; on the first `STATUS`, `PING` or `OFF` of a session the failure ends the control
session instead. A runtime jar refused for its extension ABI is answered `RestartRequired` (`bootstrap-update`)
to all four. The new host starts no module by itself; modules return with the next `APPLY`.
Replacing the runtime leaves WATCH running.

### Extension API

`ApiHost.current` (payload) reads the API jar beside the extension runtime, checks that its manifest names the
bootstrap API the game loaded (`PzTools-Bootstrap-Api`), and loads it under its own class loader (namespace
`pztools.api`). The bootstrap keeps the loaded API with the jar's digest (`AgentEntry.kept`), so a payload switch
leaves it running and the new payload's `ResidentApi` takes its frame job up again. The payload looks at the jar
about once a second (its size and time; it reads the jar only when they changed): a new digest loads and starts the
new API, which sets its hooks and takes the game's Lua environment over on its next frame, as described in the
[extension API](extension-api.md). Only a game the startup loader started loads it.

### Continuous modules

[`ContinuousRuntime.apply`](../../src/PzTools.GameExtensions.Java/java/pztools/extensions/runtime/ContinuousRuntime.java)
handles one module's slot:

1. Refuse a request for another game process (`process-changed`) or a stale revision (`revision-conflict`).
2. Read the catalogue definition and the archive; check the game version and the extension ABI.
3. If the module, world and bytes are unchanged, only the settings changed: queue them for the safe boundary, or
   acknowledge at once if they are identical to what is running.
4. Otherwise load the new archive, construct the provider, check its id, validate the settings, run `preflight`.
   A failure in any of these leaves the running generation untouched.
5. [Retire](glossary.md#retire-revoke) the running generation.
6. `initialize` the new provider. If it reports unsupported, the slot is left empty (`Unsupported`); if it
   throws, the slot is `Disabled` and the reply is `update-rejected:<exception>`. Either way the game's own
   behaviour applies: the old generation is already gone.
7. Publish the new [generation](glossary.md#generation-module) as pending; it activates at the next safe boundary.

**Revoke** is immediate: the generation stops accepting calls, drops pending settings and deactivates its provider.
It happens on a lost [control lease](glossary.md#control-lease) (5 seconds without a command), a world change, the
end of the control connection and a fault. **Retire** revokes, waits up to 5 seconds for callbacks in flight,
deactivates and closes the provider. Modules must implement `close()`; the vehicle module waits up to 5 seconds
for its game hooks to be released and removes its class transformer.

## Restart required

| Cause | Effect |
| --- | --- |
| Incompatible bootstrap | Nothing is sent to the game; all game features stop until it restarts |
| A runtime jar for another extension ABI | Extensions report `RestartRequired`, `bootstrap-update` until the game restarts; saves and the state stream go on |
| A module's retirement fails or times out | That slot is poisoned: `RestartRequired`, `retirement-failed`. Other slots keep working, but the host as a whole reports `RestartRequired` (`host-retirement-failed`) and the runtime can no longer be replaced. |
| A rejected candidate cannot be disposed | Slot poisoned, `candidate-retirement-failed` |
| Revoking a generation throws | Slot reports `RestartRequired`, `revoke-failed`, without being poisoned |

The app keeps an extension's `RestartRequired` for the rest of that game process
([`GameExtensionActivationState`](../../src/PzTools.GameBridge/GameExtensionActivationState.cs)). A module whose
`initialize` reports unsupported is not retried in the game; the app turns the extension off and blocks that
settings revision.

Retiring a module drops its references; nothing forces Java to unload its classes.

<a id="when-the-app-is-moved"></a>
## When the app is moved

A payload with the same digest at a new path only updates the stored path (refused with `BUSY` during a save). The
extensions folder is derived from the payload's folder: with an unchanged runtime digest, the host is relocated, and
modules whose bytes match keep their generation. In a game the startup loader started, the install's copy of the
extensions is used instead while the payload's folder holds the same files, and once that folder has gone
([startup loader](startup-loader.md#files)). The game-loop hook is installed once per game process, and the
DLL and bootstrap jar stay loaded from where they were first loaded.

## Saves are never replayed

A save the game has accepted belongs to the request that started it until the game's save call returns, even if the
connection drops: the save callback stays registered, and the payload cannot be swapped under it. Nothing in the
bridge or the clients sends an accepted request again. A client that loses the connection after sending reports
`completion-unknown`, and `BUSY` is retried only when nothing was sent. Queueing and deadlines are in
[game bridge](game-bridge.md#admission-and-failures).

A payload switch is refused with `BUSY` while any request session runs (a save, a profiler or notice command), and
when WATCH or extension control does not end within 3 seconds. The extension runtime is blocked only by an
extension's own save, which no shipped module performs. Continuous module replacement does not wait for saves.

## Tests

| Area | Tests |
| --- | --- |
| Payload, runtime and module replacement in a fake game | `GameBridgeReloadTests.CompatibleModuleReload_PreservesWatchAndOwnedSave_ThenReplacesPayloadWithoutRestart` (accepted save survives an archive change, epoch kept across a module reload and changed across a payload swap, identities kept, stale ticket refused, app moved, hook installed once) |
| Repeated sessions and a changed payload | `GameSaveClientTests.Bridge_LoadsChangedPayloadWithoutRestartingTheGame`, `Bridge_RepeatedSessionsReuseBootstrapPayloadAndHook_AndSaveEveryTime` |
| The frame router and the switch's pause; the resident controller's thread | The Java tests `FramesTest` (job order and isolation, the bootstrap's slot refused during a switch, one state read per frame) and `ResidentExtensionsTest` (hand-over, a switch, a pass that throws, end and restart) |
| Older bootstrap | `GameProfileBridgeTests.AGameWithAnOlderBootstrap_IsAskedToRestart_AndIsSentNothing` |
| Continuous modules | `ContinuousExtensionTests`, and the Java tests `ContinuousRuntimeTest`, `ModuleSlotsTest`, `ModuleReloadTest`, `ControlPointsTest`, `ExtensionControlTest` |

The C# tests and `ExtensionControlTest` (which runs `FramesTest` and `ResidentExtensionsTest` too) run through
`scripts/test-game-bridge.ps1` (suites `dotnet` and `control`). The other Java tests run through `scripts/test-game-extensions.ps1` (suite `extensions`); `ContinuousRuntimeTest`, `ModuleReloadTest` and `ControlPointsTest` run
inside `CheckpointRuntimeTest`. The fixtures under `tests/game-extensions-fixture/` and
`tests/game-extensions-continuous-fixture/` are synthetic modules. No test covers the 5-second drain timeout
itself (failures are simulated with a throwing `close()`), a payload swap while extension control is active, or a
payload swap refused because a save is running. Behaviour in the real game is part of the
[vehicle test guide](../contributing/e2e-vehicle-drivetrain.md).
