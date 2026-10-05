# Game extensions

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

Game extensions are optional features that run inside Project Zomboid while you play.
PZ Tools loads them through the same [game bridge](glossary.md#game-bridge) it uses for
saving; no game file is changed. This page is for players who want to know what the
extensions do, where to switch them on and when a change takes effect. The
[overview](overview.md) shows how they fit into the rest of PZ Tools.

One extension is shipped. It is a [module](glossary.md#extension-module) of its own,
with its own archive, [catalogue](glossary.md#catalogue) row, switch,
supported-version rule, options and tuning file, and it is off by default. You find it
on the **Game extensions** page of the app. The runtime can run several modules side by
side (see [below](#several-modules-on-one-connection)).

Earlier builds also shipped a *screen look* colour grade. It was removed: a filter over
the finished picture could not give a clear improvement. A setting saved for it is
ignored.

## The extensions

### Vehicle driving improvements

Experimental. Its main switch turns the extension on; expanding the card shows four
independent controls:

- Natural acceleration and shifting
- Smooth reversing
- Precise keyboard steering: steers exactly as much as a key is held, even when the frame rate is unstable
- Light around the vehicle

A control that is off keeps the game's original behaviour. The extension adjusts
driving response and leaves the game's own tyres, suspension and collisions as they
are.

The light is an addition rather than a correction. While the headlights of the vehicle
you are in are lit, it brightens the ground around that vehicle, the way a lightbar's
glow does. It is never written to the save.

Observation (probe), diagnostics and low-gear tuning are developer-only options in the
TOML settings file. See the [vehicle test guide](../contributing/e2e-vehicle-drivetrain.md) for
comparisons and status checks, or the [design](vehicle-drivetrain.md) for the
driving model and how it attaches to the game.

## When a change takes effect

The switches show your saved choices. You can change them while the game is not
connected, or while earlier changes are still waiting to apply.

| Extension | Your latest settings apply… |
| --- | --- |
| Vehicle driving improvements | once the game is running unpaused, the vehicle has stopped, acceleration is released and cruise control is off (the [safe boundary](glossary.md#safe-boundary)) |

Changes never wait for a backup.

Running extensions stay as they are through moments when the game briefly stops answering,
such as a long save or a debug tool opened on top of the game; they are only released when
the world is really left or the game stays silent for 30 seconds. Leaving the world, loading
another or closing the game turns them off and on again by themselves, and the logs record that
as information, not as a warning. The other way round, the extensions do not affect
backups: saving before a backup and the in-game save notices have their own settings,
and the vehicle controls do not change them. See
[saving the game before a backup](game-bridge.md).

The vehicle card shows what the game is actually doing:

| Card status | Meaning |
| --- | --- |
| Applied in game · Experimental | Your settings are running in the game |
| Waiting to apply in game | Saved, but not applied yet (see the table above) |
| Applying updated settings in game | A settings change is being applied |
| Off · Original driving | The extension is off; the game drives as usual |
| Turning off · Waiting for confirmation / Still active · Turning off | Switching off is in progress |
| Unsupported · Original driving | The game build or the settings did not pass the checks |
| Extension error · Original driving | The extension faulted and the game's own control is back ([pass-through](glossary.md#pass-through)) |
| Restart the game to use this extension | [Restart required](glossary.md#restart-required): nothing new is loaded until the game restarts |

## Compatibility

The [catalogue](../../config/game-extensions/catalog.tsv) declares major version 42.
Activation still requires the bytecode and structural checks against the inspected
42.20 build; declaring the range does not guarantee every 42.x patch.

**Ignore supported version range** skips only the declared version range. Identity,
structural, [admission](glossary.md#admission) and cleanup checks still apply, and the
setting does not turn the extension on by itself.

Use app, worker and JAR files from the same build. The
[game-bridge compatibility table](game-bridge.md#compatibility-and-lifecycle) defines
the runtime requirements, and [component updates](module-reload.md) explains compatible
updates, which never change the repository or save formats.

## How it works inside

### Who owns what

| Part | Responsibility |
| --- | --- |
| WinUI | Inline expandable settings rows |
| App.Core | Projects your preferences and the results actually applied in the game |
| GameExtensions | Configuration and version rules |
| Game bridge | Authentication and admission |
| Vehicle module | Driving model, adapter for the inspected build, and code transforms |

The general backup engine has no module-specific branch.

### Several modules on one connection

Continuous modules (see [capability](glossary.md#capability)) share the game process
and world selected for the [WATCH](glossary.md#watch) stream. The game is reached
through one [control lease](glossary.md#control-lease), and every continuous module
runs on it. The lease does not occupy the save-provider slot. What is shared ends
there:

- **In the game** the [host](glossary.md#extension-runtime-host) keeps one
  [slot](glossary.md#slot) per module. A slot has its own module archive and class
  loader, [generation](glossary.md#generation-module), configuration, applied revision
  and fault state. Every slot is called each frame; one that faults is
  [revoked](glossary.md#retire-revoke) by itself.
- **On the wire** `APPLY` names its module, and `STATUS`, `PING` and `OFF` take the
  module as a fourth field. With three fields they address the host as a whole: `OFF`
  then retires every module, which is what ending the lease does.
- **In the scheduler** each module has its own request, acknowledgement and failure
  record. A module that is rejected or faults is turned off in the game and in the
  saved preferences; the lease and the other modules carry on. Only losing the lease
  itself concerns every module.
- **Revisions** come from one settings file, so an edit to one extension is a new
  [settings revision](glossary.md#settings-revision) for all. A module that receives a
  new revision of the configuration it is already running acknowledges it at once: its
  provider is not called and it does not wait for a safe moment.
- **Status** is published per module, and the app shows each card from its own.

Adding a module means a catalogue row with a continuous capability, a provider archive
in its own namespace, and its configuration in the scheduler
(`RuntimeExtensionCoordinator.Configure`). Nothing in another module changes.

The per-module host calls (`ModuleControl`) live in the replaceable extension runtime,
not in the resident [bootstrap](glossary.md#bootstrap) contract, so a running game
picks them up without a restart.

## Verification

Module independence is tested at two levels, each with two synthetic modules (one under
the vehicle's catalogue name, one that exists only for the test): the host
(`ModuleSlotsTest`) and the control channel against a synthetic game JVM. The
scheduler's coordinator is tested driving the vehicle module from saved preferences.

Vehicle tests cover the model, configuration, control-session lifecycle and inspected
bytecode boundaries. Installed-class checks read a local game JAR in an isolated JVM.
Use the [vehicle test guide](../contributing/e2e-vehicle-drivetrain.md) for automated reproduction and
for the separate driving, performance and lifecycle acceptance steps.
