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
| namespace | `pztools.extensions.vehicle` | Must start with `pztools.extensions.` |
| entry class | `pztools.extensions.vehicle.VehicleDrivetrainProvider` | Inside the namespace |
| jar | `pztools-vehicle-drivetrain.jar` | `[a-z0-9-]+.jar` in the same folder |
| support scope | `Major` | `All`, `Major` or `Minor` |
| minimum, maximum inclusive | `42`, `42` | `-` for none; see below |
| title, description resource | `Extension.VehicleDrivetrain.Title` | Keys in `Resources.resw`, must start with `Extension.` |
| capability | `vehicle.drivetrain.v1` | Optional; a 10-column row means `save.prepare.v1` |

The capability, not the id, decides how a module is activated (`ExtensionCapabilities.Classify`):

| Capability | Activation | Meaning |
| --- | --- | --- |
| `save.prepare.v1` | Per save | A save provider asked for during a backup. None ships. |
| `vehicle.drivetrain.v1` | Continuous | Runs every frame for as long as it is on |
| anything else | rejected | The whole catalogue fails to parse |

Other limits: at most 64 rows, 64 KiB, 200 characters per field. The row with the vehicle id
must carry the vehicle capability.

Three readers use the deployed file: the UI controller on every card refresh, the scheduler
when it starts (falling back to the embedded copy if the file cannot be read), and the host in
the game on every `APPLY`. The Java side repeats the namespace, entry-class and jar-name checks
and only accepts continuous capabilities listed in `ContinuousRuntime.CAPABILITIES`.

### Version admission

`GameVersionSupport` (C#) and `VersionSupport` (Java) compare numbers, never strings. A game
version must look like `major.minor[.patch][-suffix]`.

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
    "vehicleDrivetrain": { "torqueEnabled": true, "reverseEnabled": true,
      "steeringEnabled": true, "areaLightEnabled": true } } } }
```

- One `revision` counts edits to the whole file, so an edit to one module is a new
  [settings revision](glossary.md#settings-revision) for all of them.
- Every write holds `settings.json.lock`, compares the revision it read
  (`ExtensionSettingsConflictException` on a mismatch), writes a temporary file and moves it
  into place. A file that cannot be read is reported, never overwritten with defaults.
- Properties of removed extensions are ignored on read and dropped on the next write.
- A missing vehicle option reads as on. An old file with `probeOnly: true` and no option
  values reads as every option off (`VehicleDrivetrainPreferenceConverter`).

`GameExtensionController` serialises the UI's writes. `ApplyEditAsync` reads the latest saved
preference after it is admitted, so queued toggles merge instead of overwriting each other.
The runtime refresh runs every second and re-reads cards only when the settings file, the
catalogue or the game version changed. The scheduler also writes this file (it turns failed
modules off), so the refresh must not trust its cache beyond those inputs.

### Delivery

`RuntimeExtensionCoordinator` runs in the StateScheduler process for the game selected by the
[WATCH](glossary.md#watch) stream. Every second (`ExtensionControlOptions.ReconcileIntervalMs`)
it reads `settings.json` and the latest runtime snapshot.

- **No local world ready.** It closes the lease and publishes `Pending` (module wanted) or
  `Disabled`, both with reason `waiting-for-local-world`.
- **World ready.** It opens one [control lease](glossary.md#control-lease) for all continuous
  modules (20-second connect timeout), then handles each module in turn:
  - Wanted on: `GameExtensionReconciler` sends `APPLY` with the module id, the revision it
    believes is applied, the new revision, `forceVersion` and the module's flat configuration
    (`Configure`). A revision it already sent gets a `PING` instead.
  - Wanted off: it sends `OFF` for that module until the game reports `Disabled`.
- **Game briefly silent.** When snapshots go stale but the process and world are unchanged, it
  keeps the lease and every module and only pings, for up to 30 seconds
  (`TransientStaleGrace`). A long save or a debugger therefore does not reinstall modules.
  After that, or when the world changes, the lease is closed and every module is revoked.

### Several modules on one connection

- **Wire.** `APPLY` names its module. `STATUS`, `PING` and `OFF` with a module field address one
  module; without it they address the host, and `OFF` then retires every module.
- **Lease.** It lasts 5 seconds in the game (`ExtensionControl.LEASE_NANOS`) and every command
  renews it. When it lapses, or the app's connection ends, the game revokes every module.
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

`ExtensionControl` ticks the host on the game thread once per frame, and only while the game
phase is `Ready`, the mode is local single-player and the game is not paused. On each tick a
slot with a pending request asks the provider's `readyToActivate`. When it says yes, the slot
calls `activate` (first time) or `updateConfig` and reports `Active`. Until then the previous
configuration keeps running. What "ready" means is the module's choice; the vehicle's rule is
in [Safe point](vehicle-drivetrain.md#safe-point-for-applying-changes).

Turning a module off never waits for that point. `OFF` revokes the generation (no new calls),
waits up to 5 seconds for calls in flight, then deactivates and closes the provider.

### Failure handling

A failure is definitive when the game reports `Unsupported`, `FaultedPassThrough` or
`RestartRequired`, or rejects the request (including a configuration the app could not build,
`configuration-rejected`). The scheduler then, for that module only:

1. sends `OFF` (or drops the lease if `OFF` gets no answer);
2. writes `enabled: false` at the revision that failed, through the revision check, so a newer
   choice the player made in the meantime is never overwritten;
3. blocks that revision and publishes the failure.

The lease and the other modules carry on. `RestartRequired` stays latched for the whole game
process, across world changes, until the game restarts. If the lease breaks while a module is
wanted off, that module is reported `Disabled` / `control-offline` and not attached again in
that world.

### Statuses keyed by extension id

The scheduler publishes a `RuntimeExtensionStatus` per module id. The app reads one through
`ExtensionActivationView.SelectCurrentStatus(observation, moduleId)`, which discards a status
older than 3 seconds and replaces one from another process, or from a world that is not ready
or not current, with `Pending` / `waiting-for-local-world`. `GameExtensionsView.Statuses` is a
dictionary by id, and each card is projected from its own entry. `ExtensionRuntimeDiagnostics`
writes each state change to the **Logs** page as `extension.runtime.changed`.

| State | Meaning |
| --- | --- |
| `Disabled` | Nothing of the module runs in this game |
| `Pending` | Accepted and waiting (`safe-boundary`), connecting, or waiting for a local world |
| `Active` | The reported revision is applied |
| `Unsupported` | The game or the request failed a check; the game's own code runs |
| `FaultedPassThrough` | The module faulted while running; the game's own code runs again ([pass-through](glossary.md#pass-through)) |
| `RestartRequired` | A generation could not be retired cleanly; nothing new loads until the game restarts ([restart required](glossary.md#restart-required)) |

`GameExtensionActivationState` keeps the options requested at each revision. When the game
reports `Active` at that revision, they become the applied options (`AppliedVehicleOptions`).
A saved preference alone is never treated as applied.

## What the card shows

The section header has the extension's title, description and main switch. Expanded, it shows
the vehicle's four option switches, a **Compatibility and status** card and **Ignore supported
version range**. The switches always show the saved preference, not the applied state, and stay
editable while no game is connected or a change is waiting. The main switch is disabled only
while the module is saved off and the current game process needs a restart.

The status card has two lines. The first is always **Supported: Build 42 series · Current game:
{version}** (**Unknown** when no fresh game version is known). The second, the hint, is the first
match in this order (`ExtensionSettingsSection.ActivationHint`), or hidden:

| Condition | Hint |
| --- | --- |
| Fresh status is `Unsupported`, `FaultedPassThrough` or `RestartRequired` | **The extension could not be applied. Check the logs for details.** |
| A change is in progress and the game said `safe-boundary` | **To apply, resume the game, stop the vehicle, release the accelerator, and turn off cruise control.** |
| A change is in progress for another reason | **Applying changes in the game.** |
| Saved on, no single-player world ready | **Saved settings will be applied when you enter a single-player game.** |
| Version outside the range, not overridden | **Outside supported range · Extension inactive** |
| No game version known, not overridden | **Waiting for game version · Extension inactive** |

"In progress" means the world is ready, the status is fresh and not failed, and either the game
reports `Pending`, the saved revision differs from the one last requested, or the module is
saved off but still applied. There is no "applied" text: when everything matches, the hint is
hidden.

The card code also has texts for per-save modules (**Off · Standard saving**, **Compatibility
checked on next save · Experimental**, **Version override · Essential checks still apply**, the
**Last request: ...** lines). They appear only for a `save.prepare.v1` module, and none ships.

## Adding an extension

1. **Module.** Put the classes in their own package under `pztools.extensions.`, implement
   `ContinuousProvider` (or `SaveProvider` for per-save work), and set the archive's
   `PzTools-Extension-Api` manifest entry to `ExtensionApi.HOST_ABI`. Add the archive to
   `build/GameBridgePayload.targets` so it lands in `game-bridge/extensions/`.
2. **Catalogue row** in `config/game-extensions/catalog.tsv`.
3. **Capability.** An existing one can be reused. A new one must be added to
   `ExtensionCapabilities.Classify` and, for a continuous module, to
   `ContinuousRuntime.CAPABILITIES`; otherwise both sides reject the whole catalogue.
4. **Texts.** `Extension.<Name>.Title` and `.Description` in every `Resources.resw` (see
   [localisation](../contributing/localization.md)).
5. **Configuration.** Add a case to `RuntimeExtensionCoordinator.Configure`. Without one every
   request fails with `configuration-rejected` and the module is turned off.
6. **Options**, if any: a typed property on `ExtensionPreference`, values in
   `GameExtensionSetting`, a branch in `GameExtensionController.ApplyEdit`, rows and a header
   glyph in `ExtensionSettingsSection`.
7. **Applied evidence.** The applied-options record (`RuntimeVehicleOptions`) is vehicle-specific.
   A new continuous module needs its own, or the card never treats it as applied.

Nothing in another module changes. `ModuleSlotsTest` runs two synthetic modules side by side,
and `ContinuousExtensionTests` shows how to add a test row and archive.

## Tests

| Area | Tests |
| --- | --- |
| Catalogue, versions, capabilities | `ExtensionVersionTests`, `ExtensionCapabilityClassificationTests`, `GameExtensionCatalogProjectionTests`, `VersionSupportTest` |
| Preferences and card projection | `GameExtensionTests`, `GameExtensionEditTests`, `GameExtensionProjectionTests`, `ExtensionActivationViewTests`, `ExtensionRuntimeStatusSelectionTests` |
| Scheduler | `GameExtensionReconciliationTests`, `GameExtensionActivationStateTests`, `ExtensionCoordinatorTests`, `RuntimeExtensionIntegrationTests` |
| Host and control channel | `ModuleSlotsTest`, `ExtensionControlTest`, `ExtensionControlConcurrencyTest` |

`scripts/test-game-extensions.ps1` runs the Java tests. Checks in a real game are in the
[vehicle test guide](../contributing/e2e-vehicle-drivetrain.md).
