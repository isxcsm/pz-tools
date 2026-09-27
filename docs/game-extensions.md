# Game extensions

[Documentation index](README.md) · [User guide](../README.md)

## Available extension

**Vehicle Driving Improvements** is the currently shipped extension. It is
experimental and off by default. In Game extensions, its main switch enables the
extension; expanding the card exposes three independent controls:

- Natural acceleration and shifting
- Smooth reversing
- Fine steering control for keyboard input

Disabled features retain the game's original control. The extension adjusts
driving response while preserving native tires, suspension and collisions. Probe,
diagnostics and low-gear tuning remain developer-only TOML options.

Switches show saved preferences. They remain editable while offline or waiting for
application; the latest settings apply after the game resumes and the vehicle is
stopped with acceleration and cruise released. Changes do not wait for a backup.
See the [vehicle test guide](e2e-vehicle-drivetrain.md) for comparisons and status
checks, or the [design](vehicle-drivetrain-design.md) for the model and adapter.

Pre-backup saving and in-game notices have separate settings. Vehicle controls do
not change those choices; see [game-save behavior](save-bridge.md).

## Compatibility

The [catalogue](../config/game-extensions/catalog.tsv) declares major version 42.
Activation still requires the inspected 42.20 bytecode and
structural checks; the range declaration does not guarantee every 42.x patch.
Force-enable bypasses only the declared version range, never identity, structural,
admission or cleanup checks, and does not turn on the extension itself.

Use matching app, worker and JAR files. The [save-bridge compatibility policy](save-bridge.md#compatibility-and-lifecycle)
defines the runtime requirements; [component replacement](module-reload.md)
explains compatible updates without changing repository or save formats.

## Implementation boundaries

WinUI presents inline expandable settings rows. App.Core projects preferences and
actual application results. GameExtensions owns configuration and version rules;
the bridge owns authentication and admission. The vehicle module owns the driving
model, inspected-build adapter and transforms. The general backup engine has no
module-specific branch.

Vehicle control shares the selected WATCH process/world, but has its own leased
session and settings revisions. It does not occupy the save-provider slot.

## Validation and acceptance

Vehicle tests cover the model, configuration, control-session lifecycle and
inspected bytecode boundaries. Installed-class checks read a local game JAR in an
isolated JVM. Use the [vehicle test guide](e2e-vehicle-drivetrain.md) for automated
reproduction and the separate driving, performance and lifecycle acceptance steps.
