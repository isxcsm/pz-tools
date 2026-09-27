# Game extensions

[Documentation index](README.md) · [Save bridge](save-bridge.md) · [Live character state](runtime-character-death.md)

## Current scope

Vehicle Drivetrain **0.2.0** is the shipped game extension. It is experimental and
defaults to OFF. The runtime uses bootstrap API **10**, extension host ABI **3**,
save protocol **6** and extension-control wire **1**.

Install matching app, worker and JARs. A resident bootstrap API 9 or older requires
one complete game restart to adopt the continuous vehicle dispatcher. Compatible
module, extension-host and bridge-payload updates then use the
[idle reload lifecycle](module-reload.md), including deployments in another folder.
Accepted work retains its owner until completion; updates do not interrupt saving
or extension cleanup. Repository data and game-save formats do not change.

## Game saving and vehicle control

No optional save provider is shipped. When pre-backup game saving is enabled and
the selected world is active, the bridge calls the original
`GameWindow.save(true)` on the game thread. The separate game-save and countdown
preferences, localized notices, recovery stamp and pause/death/permission checks
remain available. See [game-save behavior and limits](save-bridge.md).

Vehicle Drivetrain is a continuous provider with a declared Build 42 version range.
It uses the selected WATCH process/world through a leased control session and
settings revisions. It does not occupy the save-provider slot or wait for a backup
to apply a settings change.

Driving settings expose three independent switches: acceleration/transmission,
smooth reverse and fine keyboard steering. Disabled paths retain original control.
Probe, diagnostics and low-gear tuning remain developer-only TOML options. This is
not a native tire/collision overhaul or a claim of real horsepower simulation.
See the [design](vehicle-drivetrain-design.md) and
[user E2E procedure](e2e-vehicle-drivetrain.md).

## Layers and version policy

WinUI presents inline expandable settings rows. App.Core projects preferences and
actual application results. GameExtensions owns configuration and version rules;
the bridge owns authentication and admission. The vehicle module owns the driving
model, inspected-build adapter and transforms. The general backup engine has no
module-specific branch.

The shared catalogue contains Vehicle Drivetrain with Major **42–42** scope
(all 42.x versions, not 41.x or 43.x). Structural and bytecode admission checks
remain independent: only the inspected 42.20 binary contracts have been verified,
so other 42.x binaries can still be rejected by those safety checks. A declared
version range is not a claim that every 42.x build has passed driving tests.
Explicit version override bypasses
only the declared range, never structural, identity, admission or cleanup checks.
An override does not establish compatibility with unexamined game binaries.

The common `SaveProvider` and checkpoint contracts remain part of the host API for
compatibility and synthetic transport/reload tests. Their presence does not select
an optional save implementation for backups. Catalogue entries, deployed archives
and actual module results define which extension is available.

## Validation and acceptance

Use current harness/TRX output for automated results. Generic host tests cover
archive validation, unchanged bytes, relocation, stale resolutions, in-flight
ownership and retirement with synthetic providers. Vehicle tests cover the model,
configuration, control-session lifecycle and inspected bytecode boundaries.

Installed-class checks read a local game JAR in an isolated JVM. They do not attach
to a running game or establish live driving behavior. Real frame time, driving
feel, mod interactions and world-restoration acceptance require the
[disposable-world vehicle procedure](e2e-vehicle-drivetrain.md).
