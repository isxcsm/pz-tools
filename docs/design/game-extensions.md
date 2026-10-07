# Game extensions

[Documentation index](../README.md)

A game extension is an optional module that runs inside the Project Zomboid process. PZ Tools
loads it through the [game bridge](game-bridge.md) and changes game classes in memory only.
One extension ships: **Vehicle driving improvements** (`pztools.vehicle-drivetrain`), off by
default. Its driving model is in [Vehicle model](vehicle-drivetrain.md). The player's steps
are in [Better vehicle controls](../guides/vehicle-controls.md).

## Parts and where they live

| Part | Code | Job |
| --- | --- | --- |
| Catalogue | [config/game-extensions/catalog.tsv](../../config/game-extensions/catalog.tsv) | One row per module: identity, archive, supported game versions, capability |
| Catalogue and version rules | `ExtensionCatalog`, `GameVersionSupport`, `ExtensionCapabilities` in [PzTools.GameExtensions](../../src/PzTools.GameExtensions/) | Parse and validate rows, classify capabilities, match game versions |
| Saved preferences | `ExtensionSettingsStore` (same project) | `settings.json` with a revision counter |
| Extension descriptors | `ExtensionDescriptors` (same project), and each extension's own descriptor (`VehicleDrivetrainExtension`) | What the app knows of an extension beyond its row: its switches, glyph and safe-point hint, how its configuration is built, how earlier versions saved its switches |
| UI controller | [GameExtensionController](../../src/PzTools.App.Core/GameExtensionController.cs), [ExtensionActivationView](../../src/PzTools.App.Core/ExtensionActivationView.cs) | Write preferences, project cards and per-module runtime status |
| Card | [ExtensionSettingsSection](../../src/PzTools.App/ExtensionSettingsSection.cs) | The expandable section on the **Game extensions** page |
| Scheduler | [RuntimeExtensionCoordinator](../../src/PzTools.State.Scheduler/RuntimeExtensionCoordinator.cs) with `GameExtensionReconciler`, `GameExtensionActivationState`, `GameExtensionClient` in [PzTools.GameBridge](../../src/PzTools.GameBridge/) | Deliver preferences to the game, track what is applied, turn failed modules off |
| Control channel in the game | `ExtensionControl` in [PzTools.GameBridge.Agent](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/ExtensionControl.java) | Control lease, per-frame tick on the game thread |
| Host in the game | `ModuleHost`, `ContinuousRuntime` in [PzTools.GameExtensions.Java](../../src/PzTools.GameExtensions.Java/java/pztools/extensions/runtime/) | One slot per module: load, apply, update, fault, retire |
| Module | [PzTools.GameExtensions.VehicleDrivetrain](../../src/PzTools.GameExtensions.VehicleDrivetrain/) | `pztools-vehicle-drivetrain.jar` |

The backup engine has no module-specific code.

## The catalogue

`catalog.tsv` is tab-separated, one module per row, `#` starts a comment.
[build/GameBridgePayload.targets](../../build/GameBridgePayload.targets) copies it, the
module archives and the tuning file to `game-bridge/extensions/` in the app folder. The
`PzTools.GameExtensions` assembly also embeds a copy (`ExtensionCatalog.BuiltIn`).

| Column | Example | Rule |
| --- | --- | --- |
| id | `pztools.vehicle-drivetrain` | `^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$`, at most 80 characters, unique |
| module version | `0.2.0` | A parsable version |
| namespace | `pztools.extensions.vehicle` | Must start with `pztools.extensions.` (checked in the game) |
| entry class | `pztools.extensions.vehicle.VehicleDrivetrainProvider` | Inside the namespace (checked in the game) |
| jar | `pztools-vehicle-drivetrain.jar` | `[a-z0-9-]+.jar` in the same folder (checked in the game) |
| support scope | `Major` | `All`, `Major` or `Minor` |
| minimum, maximum inclusive | `42`, `42` | Both `-` for `All`. `Major` and `Minor` need a minimum; a maximum of `-` means no upper bound. |
| title, description resource | `Extension.VehicleDrivetrain.Title` | Keys in `Resources.resw`, must start with `Extension.` |
| capability | `vehicle.drivetrain.v1` | Required: a row without it is refused |

The capability, not the id, decides how a module is activated (`ExtensionCapabilities.Classify`):

| Capability | Activation | Meaning |
| --- | --- | --- |
| `save.prepare.v1` | Per save | A save provider asked for during a backup. None ships, and the app shows no card for one. |
| `continuous.v1` | Continuous | Runs every frame for as long as it is on |
| `vehicle.drivetrain.v1` | Continuous | The first name of `continuous.v1` (`ExtensionCapabilities.LegacyContinuous`), still read |
| anything else | rejected | The whole catalogue fails to parse |

Other limits: at most 64 rows, 64 KiB, 200 characters per field.

Four readers use the deployed file: the UI controller when the file changed (`GameExtensionController`
keeps it with the file's time and length), the scheduler when it starts (falling back to the
embedded copy if the file cannot be read), the [resident request](startup-loader.md#resident-extensions)
while the startup loader is installed (`ResidentExtensionRequest`, when a file it is built from changed), and the
host in the game on every `APPLY`. Only the Java side checks the namespace, entry class and jar name,
with one parser (`Catalogue`) that `ModuleHost` uses when the host loads and `ContinuousRuntime` on
every `APPLY`. Besides `save.prepare.v1` it accepts the continuous capabilities in
`Catalogue.CONTINUOUS`: `continuous.v1`, and `vehicle.drivetrain.v1`, the earlier name of the same
contract.

### Version admission

`GameVersionSupport` (C#) and `VersionSupport` (Java) compare numbers, never strings. A game
version must look like `major.minor[.patch][-suffix]` (or `+suffix`), at most four digits per
number.

| Scope | Bounds | Matches |
| --- | --- | --- |
| `All` | both `-` | every version, including an unknown one |
| `Major` | `42` | every 42.x when the bounds are 42–42 |
| `Minor` | `42.20` | 42.20 and every 42.20.x |

An unknown game version never matches a `Major` or `Minor` range. The check runs in the app
(to choose the card's hint) and again in the game host (`ContinuousRuntime.apply`, which
rejects with `version-mismatch`). Matching the range does not mean the module works: the
vehicle module runs its own runtime and bytecode checks, reviewed against Build 42.20.4
([details](vehicle-drivetrain.md#how-it-attaches-to-the-game)).

### Ignoring the supported version range

**Ignore supported version range** stores `forceVersion: true` in the module's preference. It
is sent with every `APPLY` and skips only the range check, in the app and in the game. It does
not turn the module on. The archive's API version (`PzTools-Extension-Api` manifest entry,
`ExtensionApi.HOST_ABI`), the provider's preflight and initialisation, and its bytecode checks
still run.

## From the switch to the game

### Saved preferences

Preferences live in `%LOCALAPPDATA%/PzTools/extensions/settings.json`:

```json
{ "schemaVersion": 1, "revision": 7,
  "extensions": { "pztools.vehicle-drivetrain": { "enabled": true, "forceVersion": false,
    "options": { "reverseEnabled": false, "steeringEnabled": true } } } }
```

- One `revision` counts edits to the whole file, so an edit to one module is a new
  [settings revision](glossary.md#settings-revision) for all of them.
- Every write holds `settings.json.lock`, compares the revision it read
  (`ExtensionSettingsConflictException` on a mismatch), writes a temporary file and moves it
  into place. A file that cannot be read is reported, never overwritten with defaults.
- `options` holds the extension's own switches by key, as its descriptor names them
  (`ExtensionDescriptor.Options`); a switch not saved reads as its default (on, for each of the
  vehicle's). An edit saves the switch it changes. The store knows no switch by name: keys are
  checked only for their form (letters, digits, `.`, `_`, `-`; at most 64).
- Files from before `options` kept the vehicle's switches in a `vehicleDrivetrain` object of the
  vehicle's preference. With no `options` saved, the store hands the preference's other
  properties to the extension's descriptor (`ExtensionDescriptor.LegacyOptions`); the vehicle's
  (`VehicleDrivetrainLegacyOptions`) reads that object with its old rules: a missing switch is
  on, and an old file with `probeOnly: true` reads as every switch off. The next write keeps
  the values in `options` and leaves the old object behind.
- Other properties of a preference (those of an extension that no longer exists) are ignored
  on read and dropped on the next write. Entries for ids the catalogue no longer lists are kept.

`GameExtensionController` serialises the UI's writes. `ApplyEditAsync(id, setting, value)` takes
`enabled`, `forceVersion` or the key of one of the extension's switches; any other key, or an
unknown id, is refused with `InvalidDataException`. It reads the latest saved preference after
it is admitted, so queued toggles merge instead of overwriting each other, and writes it at the
revision it read (`GameExtensionService.Save`); the cards after the write come from what was
written, without reading the file again.
The runtime refresh runs every second and re-reads cards only when the settings file, the
catalogue or the game version changed. The scheduler also writes this file (it turns failed
modules off), so the refresh must not trust its cache beyond those inputs.

### Delivery

`RuntimeExtensionCoordinator` runs in the StateScheduler process for the game selected by the
[WATCH](glossary.md#watch) stream. Every `reconcile_interval_ms` (1 second by default, 250–1000 ms,
in `[extensions]` of the state-scheduler [advanced settings](../reference/advanced-settings.md))
it reads `settings.json` and the latest runtime snapshot.

- **No local world ready.** It closes the lease and publishes `Pending` (module wanted) or
  `Disabled`, both with reason `waiting-for-local-world`.
- **World ready.** It opens one [control lease](glossary.md#control-lease) for all continuous
  modules (`connect_timeout_seconds`, 20 by default), then handles each module in turn:
  - Wanted on: `GameExtensionReconciler` sends `APPLY` with the module id, the revision it
    believes is applied, the new revision, `forceVersion` and the module's flat configuration
    (`ContinuousConfiguration.For`). A revision it already sent gets a `PING` instead.
  - Wanted off: it sends `OFF` for that module until the game reports `Disabled`.
- **Game briefly silent.** When snapshots go stale but the process and world are unchanged, it
  keeps the lease and every module and only pings, for up to 30 seconds
  (`TransientStaleGrace`). A long save or a debugger therefore does not reinstall modules.
  After that, or when the world changes, the lease is closed and every module is revoked.

### Several modules on one connection

- **Wire.** `APPLY` names its module. `STATUS`, `PING` and `OFF` with a module field address one
  module; without it they address the host, and `OFF` then retires every module.
- **Lease.** It lasts 5 seconds in the game (`ExtensionControl.LEASE_NANOS`) and every command
  renews it. When it lapses, or the app's connection ends, the game revokes every module, unless
  the [startup loader](startup-loader.md#resident-extensions) started the game: its resident
  controller then takes the modules over as they are.
  `APPLY` and `OFF` time out after 15 seconds, other commands after 3.
- **Slots.** `ModuleHost` keeps one `ContinuousRuntime` slot per module, at most 16. A slot has
  its own archive, class loader, [generation](glossary.md#generation-module), configuration,
  applied revision and fault state. Every slot is ticked each frame; one that faults is revoked
  alone.
- **Scheduler.** Each module has its own request, acknowledgement and failure record. Only
  errors that concern the lease (I/O, bridge errors, cancellation) affect every module.
- **Status.** Published per module id.

`ModuleControl` (the per-module host calls) is part of the replaceable extension runtime, not
the resident [bootstrap](glossary.md#bootstrap), so a running game picks up changes to it on a
[component update](module-reload.md).

A module compiles against the runtime jar, and its class loader's parent is the runtime's. What it may use is
the resident API (`pztools.extensions.api`), `pztools.extensions.runtime.spi` (`FrameListener` for per-frame
work, `CooperativeCapture` for a save done in steps) and `pztools.extensions.runtime.input` (key timing). The
host's own classes are package-private; only `ModuleHost`, which the bootstrap loads, and the contracts the
bridge calls (`ModuleControl`, `CooperativeTask`) are public.

### In the game

`ContinuousRuntime.apply` checks, in order: process id, revision (`revision-conflict` if the
expected applied revision differs), catalogue row, version range, archive API version. Then:

- **Same generation** (same game class loader, world, catalogue row and archive digest): the
  configuration is validated. If it equals what is already applied, the new revision is
  acknowledged at once as `Active`; this is the normal case when another module's settings
  changed. Otherwise it becomes the pending request and the reply is `Pending` /
  `safe-boundary`.
- **New generation:** the module is loaded in its own class loader, validated and preflighted,
  the old generation is retired, and the new one is initialised. The reply is `Pending` /
  `safe-boundary`.

A request that throws is answered `update-rejected:<exception class>`, and the exception itself is written to
the game's standard error (`[PzTools extensions] Update rejected for <id>: …`), as is one thrown on the game
thread (`activation-failed:<exception class>`). A reason the module gives (preflight, initialisation,
`failureReason`) is passed on cut to 256 characters, with control characters replaced.

`ExtensionControl` ticks the host on the game thread once per frame, and only while the game
phase is `Ready`, the mode is local single-player and the game is not paused. On each tick a
slot with a pending request asks the provider's `readyToActivate`. When it says yes, the slot
calls `activate` (first time) or `updateConfig` and reports `Active`. Until then the previous
configuration keeps running. What "ready" means is the module's choice; the vehicle's rule is
in [Safe point](vehicle-drivetrain.md#safe-point-for-applying-changes).

Turning a module off never waits for that point. `OFF` revokes the generation (no new calls),
waits up to 5 seconds for calls in flight, then deactivates and closes the provider.

### Control points

A module that changes game code does it with its own bytecode, and that code calls a named control point
(`ControlPoints`, in the resident extension API, so the game's class loader and every module generation see the
same class). Two calls exist: `call(point, target, mode, argument)`, which returns an `int` outcome, and
`observe(point, target, a, b, c)`, which only looks. What the mode and the outcome mean is the module's own
contract with the code it generated; the API holds no game concept. While active, the module registers a handler
for its point, with its provider as the owner.

- **Fail open.** With no handler the call returns 0, which generated code must treat as "run the game's own code".
- **One owner.** A second registration for the same point is refused.
- **No re-entry.** A call on a thread that is already inside any point's handler returns 0.
- **Fault latch.** A handler that throws is not called again and every later call returns 0. On its next tick the
  host reports the owning module `FaultedPassThrough` with the reason `<point>-callback-failed` and revokes it.
- **Drain.** `unregister` refuses new calls at once and returns a `Lease` to await the calls still in flight. The
  same `Lease` class counts the host's own lifecycle calls into a generation.

The vehicle module's point is `vehicle` ([how it attaches](vehicle-drivetrain.md#how-it-attaches-to-the-game)).

### Failure handling

A failure is definitive when the game reports `Unsupported`, `FaultedPassThrough` or
`RestartRequired`, or rejects the request (including a configuration the app could not build,
`configuration-rejected`). The scheduler then, for that module only:

1. sends `OFF` (or drops the lease if `OFF` gets no answer);
2. writes `enabled: false` at the revision that failed, through the revision check, so a newer
   choice the player made in the meantime is never overwritten;
3. blocks that revision and publishes the failure.

`RestartRequired` with the reason `bootstrap-update` (an app update the running game's resident classes do
not fit) skips step 2: nothing failed, so the switch keeps its setting and the extension returns with the next
game.

The lease and the other modules carry on. `RestartRequired` stays latched for the whole game
process, across world changes, until the game restarts.

The [resident request](startup-loader.md#resident-extensions) follows the same rule for a
configuration it cannot build: the module is written `off`, so a game running without the app
runs its own code too. It writes no settings; while the app is connected, the scheduler does.

A link that cannot be made or breaks (the helper cannot attach, the bootstrap is busy with a payload
reload, the connection ends or a command gets no answer) is not definitive: the game was not asked,
or could not answer. Every wanted module is reported `FaultedPassThrough` / `connection-unavailable`,
the preference stays, and the scheduler tries again, waiting twice as long after each failure in a
row, up to 30 seconds (each attempt starts a helper process). If the lease breaks while a module is
wanted off, that module is reported `Disabled` / `control-offline` and not attached again in
that world.

### Statuses keyed by extension id

The scheduler publishes a `RuntimeExtensionStatus` per module id. The app reads one through
`ExtensionActivationView.SelectCurrentStatus(observation, moduleId)`, which discards a status
older than 3 seconds and replaces one from another process, or from a world that is not ready
or not current, with `Pending` / `waiting-for-local-world`. `GameExtensionsView.Statuses` is a
dictionary by id, and each card is projected from its own entry. `ExtensionRuntimeDiagnostics`
writes each state change to the **Logs** page as `extension.runtime.changed`, and a newer
diagnostics sample in an unchanged state as `extension.runtime.sample`, at most once every 10 seconds.

| State | Meaning |
| --- | --- |
| `Disabled` | Nothing of the module runs in this game |
| `Pending` | Accepted and waiting (`safe-boundary`), connecting, or waiting for a local world |
| `Active` | The reported revision is applied |
| `Unsupported` | The game or the request failed a check; the game's own code runs |
| `FaultedPassThrough` | The module faulted while running; the game's own code runs again ([pass-through](glossary.md#pass-through)) |
| `RestartRequired` | A generation could not be retired cleanly, or (`bootstrap-update`) the app was updated in a way only a restart of the game takes up; nothing new loads until the game restarts ([restart required](glossary.md#restart-required)) |

`GameExtensionActivationState` keeps, for each revision the scheduler sent, the SHA-256 of the
configuration it sent with it (`ContinuousConfiguration.Digest`, taken from `GameExtensionReconciler.Sent`).
When the game reports `Active` at such a revision, that digest becomes the status's
`AppliedConfiguration`, and stays while the same generation runs that revision. The card treats a
module as applied only with it, whatever the module. The game's `STATUS` does not carry it: it is
the app's own record of what it asked for. A saved preference alone is never treated as applied.

## What the card shows

The section header has the extension's glyph (`ExtensionDescriptor.Glyph`: a car for the vehicle,
a puzzle piece otherwise), title, description and main switch. Expanded, it shows the extension's
own switches in its descriptor's order (the vehicle's four: acceleration, reversing, steering,
light), a **Compatibility and status** card and **Ignore supported version range**. The switches always show the saved preference, not the applied state, and stay
editable while no game is connected or a change is waiting. The main switch is disabled only
while the module is saved off and either the current game process needs a restart or the running
game's version is outside the supported range and the range is not ignored (the game would reject
the request). A switch that is on can always be turned off. With no game version known, turning
it on is saved and checked when a game starts.

The status card has two lines. The first is always **Supported: Build 42 series · Current game:
{version}** (**Unknown** when no fresh game version is known). The second, the hint, is the first
match in this order (`ExtensionSettingsSection.ActivationHint`), or hidden:

| Condition | Hint |
| --- | --- |
| Fresh failed status with reason `version-mismatch` | **Outside supported range · Extension inactive** |
| Fresh `RestartRequired` with reason `bootstrap-update` (`ExtensionActivationView.AwaitsGameRestart`) | **Restart the game.** (the game-link card's text) |
| Any other fresh `Unsupported`, `FaultedPassThrough` or `RestartRequired` status | **The extension could not be applied. Check the logs for details.** |
| A change is in progress and the game said `safe-boundary` | The extension's own hint (`ExtensionDescriptor.SafeBoundaryHintKey`); the vehicle's is **To apply, resume the game, stop the vehicle, release the accelerator, and turn off cruise control.**, any other's **Applying changes in the game.** |
| A change is in progress for another reason | **Applying changes in the game.** |
| Saved on, no single-player world ready | **Saved settings will be applied when you enter a single-player game.** |
| Version outside the range, not overridden | **Outside supported range · Extension inactive** |
| No game version known, not overridden | **Waiting for game version · Extension inactive** |

"In progress" means the world is ready, the status is fresh and not failed, and either the game
reports `Pending`, the saved revision differs from the one last requested, or the module is
saved off but still applied ("applied" is the evidence in
[Statuses keyed by extension id](#statuses-keyed-by-extension-id)). There is no "applied" text:
when everything matches, the hint is hidden.

Only continuous modules have a card (`GameExtensionService.ReadCards`). A `save.prepare.v1` row
has none: nothing in the app asks the game for a save provider yet (the bridge's
`GameSaveClient.RequestProviderAsync` is kept for that, used only by tests), so a switch for one
would save a preference nothing reads.

## Adding an extension

1. **Module.** Put the classes in their own package under `pztools.extensions.`, implement
   `ContinuousProvider` (or `SaveProvider` for per-save work), and set the archive's
   `PzTools-Extension-Api` manifest entry to `ExtensionApi.HOST_ABI`. Add the archive to
   `build/GameBridgePayload.targets` so it lands in `game-bridge/extensions/`.
2. **Catalogue row** in `config/game-extensions/catalog.tsv`, with the capability `continuous.v1`.
   A new capability must be added to `ExtensionCapabilities.Classify` and, for a continuous
   module, to `Catalogue.CONTINUOUS`; otherwise both sides reject the whole catalogue.
3. **Texts.** `Extension.<Name>.Title` and `.Description` in every `Resources.resw` (see
   [localisation](../contributing/localization.md)), and the title and description of each switch.
4. **Descriptor**, in a file of the extension's own (as `VehicleDrivetrainExtension.cs`), registered
   in `ExtensionDescriptors`:
   - `Configuration`, an `IContinuousConfiguration`: builds the flat configuration from the saved
     preference and the extension's tuning files, and lists those files (`Inputs`). Without one
     every request fails with `configuration-rejected` and the module is turned off.
   - `Options`, if any: each switch's key, title and description resources and default, in the
     order the section shows them. The section, `ApplyEditAsync` and the settings file take them
     from here.
   - `Glyph` and `SafeBoundaryHintKey`, if the defaults do not fit.
   - `LegacyOptions`, only if earlier versions saved the extension's switches another way.

   Nothing else in the app changes: the scheduler, the resident request, the card and the
   applied evidence work by id and capability.

Nothing in another module changes. `ModuleSlotsTest` runs two synthetic modules side by side,
and `ContinuousExtensionTests.cs` shows how to add a test row and archive.

## Tests

C# tests are in `tests/PzTools.Backup.Tests`, Java tests under `tests/game-extensions` and
`tests/extension-control`. The names are file names; several C# files hold parts of the
`GameSaveClientTests` class.

| Area | Tests |
| --- | --- |
| Catalogue, versions, capabilities | `ExtensionVersionTests`, `ExtensionCapabilityClassificationTests`, `GameExtensionCatalogProjectionTests`, `VersionSupportTest` |
| Preferences and card projection | `GameExtensionTests`, `GameExtensionEditTests`, `GameExtensionProjectionTests`, `ExtensionActivationViewTests`, `ExtensionRuntimeStatusSelectionTests` |
| Scheduler | `GameExtensionReconciliationTests`, `GameExtensionActivationStateTests`, `ExtensionCoordinatorTests`, `RuntimeExtensionIntegrationTests` |
| Host and control channel | `ModuleSlotsTest`, `CatalogueTest`, `ControlPointsTest`, `ExtensionControlTest`, `ExtensionControlConcurrencyTest` |

`scripts/test-game-extensions.ps1` runs the Java tests under `tests/game-extensions`.
`scripts/test-game-bridge.ps1` runs it as its `extensions` suite, the control-channel tests as
`control`, and (without `-PrepareOnly`) the `GameSaveClientTests` that need the built fixture
archives as `dotnet` ([suites](../contributing/development.md#game-bridge-tests)). Checks
in a real game are in the [vehicle test guide](../contributing/e2e-vehicle-drivetrain.md).
