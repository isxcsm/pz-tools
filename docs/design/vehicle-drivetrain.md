# Vehicle model

[Documentation index](../README.md)

**Vehicle driving improvements** is the continuous [game extension](game-extensions.md)
`pztools.vehicle-drivetrain`, version 0.2.0, capability `vehicle.drivetrain.v1`, shipped as
`pztools-vehicle-drivetrain.jar`. The source is in
[PzTools.GameExtensions.VehicleDrivetrain](../../src/PzTools.GameExtensions.VehicleDrivetrain/java/pztools/extensions/vehicle/).
The player's steps are in [Better vehicle controls](../guides/vehicle-controls.md).

The model, the adapter and the bytecode checks are tested against synthetic game classes.
Real driving has not been accepted yet: what the game's force and time values mean physically,
fuel use and engine noise, and module updates in a running game still need live testing
([vehicle test guide](../contributing/e2e-vehicle-drivetrain.md)). Multiplayer is not supported
by any part of it.

## The four options

| Switch | Key | Takes over | Writes |
| --- | --- | --- | --- |
| **Natural acceleration and shifting** | `torque_enabled` | `CarController.control_ForwardNew` | engine force, braking force 0, throttle, gear, engine RPM; clears the parking-brake release flag |
| **Smooth reversing** | `reverse_enabled` | `CarController.control_Reverse` | the same fields, gear R |
| **Precise keyboard steering** | `steering_enabled` | the steering interpolation block in `CarController.update` | `vehicleSteering` |
| **Light around the vehicle** | `area_light_enabled` | nothing; runs once per frame | one `IsoLightSource` in the cell's lamppost list |

A switch that is off leaves that part to the game. The extension never touches mass, cargo,
tyre grip, suspension, collisions, braking (`control_Braking`), coasting (`control_NoControl`
always runs the game's code), gamepad steering or `ClientControls`.

Writing gear, throttle and RPM is shared state: the game also uses those values for fuel use
and engine sound, so those effects need live testing.

## How it attaches to the game

`VehicleDrivetrainProvider` registers a `ClassFileTransformer` for
`zombie.core.physics.CarController` and retransforms the loaded class. No file of the game
installation is changed. `VehicleBytecode.transform` changes `update()` as follows:

1. Once the game has resolved the control mode, it calls `VehicleHooks.tryControl(controller,
   mode, speed)` with mode Forward, Reverse, Braking or other.
2. The calls to `control_NoControl`, `control_ForwardNew` and `control_Reverse` are skipped only
   when the outcome has the `APPLIED` bit.
3. `DIRECTION_HOLD` switches the mode to Braking, sets `isBreak`, clears `isGas` and `isGasR`
   and sets the throttle to 0, so the game's braking and signal code runs.
4. `OWN_OFFROAD` makes the `isDoingOffroad()` read before the game's gear-dependent offroad
   penalty return false for that update.
5. At the start of the steering block, a second `tryControl` with mode `STEERING`; `APPLIED`
   skips the block. Angle limits, tyre processing, wheel display and native calls after it
   still run.
6. Each `Bullet.controlVehicle` call passes its arguments to `observeNative` first, for
   diagnostics only.

`VehicleHooks` ignores a re-entrant call on the same thread. An exception or an invalid outcome marks
the registration failed; every later call returns `VANILLA`, and the host's next tick reports
`FaultedPassThrough`.

### Compatibility checks

Before it installs anything (`preflight`, then `initialize`):

- The Java runtime must be feature version 25 with class retransformation.
- `VehicleAccess` resolves every field and method it uses with its exact type and static or
  instance access. Three groups are optional: key bindings and the input gate (without them
  steering keys are not timed) and lighting (without it only the light is unavailable).
- `VehicleBytecode` requires each `control_*` call and `control_Braking` exactly once in
  `update()`, `Bullet.controlVehicle` twice, and the expected steering and offroad layouts.
- The code that can be skipped is pinned: a normalised SHA-256 of `control_NoControl`,
  `control_ForwardNew`, `control_Reverse` and the steering and offroad blocks must equal
  `CONTROL_CONTRACTS`, reviewed against Build 42.20.4. Debug information, constant-pool layout,
  method order and no-ops are ignored. A game update that changes those methods needs a review
  and new hashes, because skipping changed code could silently drop new game or mod behaviour.
- `VehiclePatchContract` checks the call order and that every path from the dispatch to the
  braking decision passes the game's mode checks and back-signal update, with no early exits,
  handlers, loops or re-entry in that stretch. `control_Braking` is required even though it is
  never skipped, because `DIRECTION_HOLD` relies on it.
- The transformed class must pass the class-file verifier.

Every later retransformation runs the same checks on the bytes it receives. If they fail, the
transformer returns the input unchanged and the provider reports `controller-contract-changed`.
It never replaces another transformer's output with bytes read from disk. Preflight for a
module update observes the existing transformer chain, but cannot see transformers registered
later or changes made through JVMTI or JNI.
[VerifyInstalledVehicleBytecode](../../tests/game-extensions/VerifyInstalledVehicleBytecode.java)
runs the checks against a local game JAR in a separate JVM.

### Rules for code in the hooks

- **All or nothing.** Every handle, type, gear object and output value is checked before the
  first field is written. Model output must be finite, |force| ≤ 1,000,000, RPM 0–7000,
  throttle 0–1, force in the direction of travel, gear in range; anything else throws and
  faults the module.
- **Nothing slow.** Prepared field and method handles only: no file access, Lua, reflection
  lookups or settings parsing per update. Per-vehicle state is cached in weak maps.
- **Fresh state.** A frame gap, a different driver, a declined step or a fallback resets the
  model. When it takes over again it picks a gear from the current speed.
- **Time.** The step is `GameTime.getPhysicsSecondsSinceLastUpdate()`. Zero, negative or more
  than `max_dt_seconds` (0.1 s by default) falls back to the game, so pausing cannot cause a
  catch-up burst.
- **Duplicates.** A second propulsion call in the same frame, or a call off the game thread,
  falls back. A second steering call in the same frame for the same driver rewrites the angle
  it applied before the tyre step, so the tyre correction is not applied twice.

## When each part applies

Propulsion (`VehicleControl.tryControl`, `VehicleAccess.read`, `VehicleProfile.resolve`) needs
all of these; otherwise the game's code runs and the diagnostics reason names the first failed
check, in this order:

| Rule | Reason |
| --- | --- |
| The option for this mode is on | `forward-disabled`, `reverse-disabled` |
| Single-player, the activation's world | `multiplayer-unsupported`, `world-or-controller-changed` |
| The driver is the local player | `not-local-driver` |
| Not towed, not burnt, not towing a burnt vehicle | `towed-or-burnt`, `burnt-tow-unsupported` |
| Engine running | `engine-not-running` |
| Four wheels, each radius 0.05–5 | `unsupported-wheels`, `invalid-wheel-radius` |
| Mode Forward or Reverse | `original-coast-or-brake` |
| Valid time step, first call this frame | `invalid-or-long-dt`, `duplicate-frame` |
| Engine family `generic`, `van`, `jeep` or `firebird`, 3–5 gears, script top speed 20–300 km/h | `unsupported-profile` |

Ordinary towing is allowed.

Steering (`VehicleAccess.readSteering`) is checked separately and does not need a running
engine or a known engine family. It needs: single-player, the local player driving, keyboard
control (`getJoypad() == -1`), not towed or burnt, four wheels, and a game step that does not
overshoot (`0.06 × m × f < 1`, see [keyboard steering](#keyboard-steering)).

## Safe point for applying changes

Turning the extension on, and every later configuration change, waits until
`VehicleDrivetrainProvider.readyToActivate` (`VehicleAccess.ready`) returns true on the game
thread. That requires:

- single-player and the activation's world;
- for every player in `IsoPlayer.players` (the local players) who is in a vehicle, driver or
  passenger: speed at most 0.5 km/h, throttle at most 0.01 and cruise control (`isRegulator`)
  off.

Players on foot do not block it, and vehicles nobody local is in are not checked. The host only
ticks while the game is unpaused, which is why the card asks the player to resume the game.
While a change waits, the previous configuration keeps running, light included.

The scheduler builds the configuration from the tuning files only when the settings revision
changes, or when it attaches to a new world or lease. Editing the override file alone does
nothing until then. A new revision whose configuration equals the applied one (for
example a change to another module) is acknowledged without waiting.

## The driving model

`DrivetrainModel.step` runs once per propulsion call. Its throttle input is always 1: the game
has already resolved the mode, including cruise control and input gates. Its demand input is the
game's own pedal (`BaseVehicle.throttle`) as the game sets it for this update, before the control
branch: rising while the accelerator is held, 0.5 while cruise control alone keeps the speed. Demand
decides only the kick-down below. Force is in the game's own units, not newtons or horsepower.

### Forward force

The base is the game's `control_ForwardNew` envelope:

```text
cap = enginePower × firstGear × (0.30 + rpm / 30000) × clamp(1 − speedKph / 200, 0, 1)
      × force_scale × trait × offroad
firstGear = 1.5 × low_gear_boost   while in gear 1 or below maxSpeed / gearCount, else 1
requested = cap × (1 + forward_torque_boost_fraction × torqueShape(rpm)) × throttle × governor
```

`torqueShape` rises from `idle_torque_fraction` at 0 RPM to 1 at the family's peak, falls to 0.8
at 90% of redline and to 0 at 105%. The boost is at most 10% of the base envelope, but the whole
behaviour can differ by more, because RPM and gears follow this model and the game's extra fade
above 6,000 RPM is not reproduced. Gear ratios steer RPM and shifting only; they do not scale
force.

### Reverse force

```text
cap = enginePower × (0.75 + rpm / 24000) × clamp((7000 − rpm) / 1000, 0, 1)
      × force_scale × reverse_force_ratio × trait × offroad
```

### Ramps

Throttle rises to 1 over `forward_ramp_seconds` (0.3 s) or `reverse_ramp_seconds` (0.8 s).
Delivered force moves towards `requested` at a bounded rate (forward: `enginePower × 0.65 ×
force_scale × low_gear_boost × trait` per ramp; reverse: `cap` per ramp), so leftover RPM cannot
cause a spike. A lower cap from speed, trait or surface applies at once.

### Speed limits and traits

| Case | Rule |
| --- | --- |
| Forward | Full force up to `maxSpeed` (× 1.15 with Speed Demon), fading to 0 at that + 20 km/h. `forward_governor_start_fraction` < 1 starts the fade earlier. |
| Forward, Sunday Driver | Force × 0.75; above 60% of `maxSpeed` also × max(0, (0.75 × maxSpeed + 20 − speed) / 20), the game's factor, which can briefly exceed 1 |
| Forward, Speed Demon | RPM is computed from speed / 1.15, so gears do not cap the trait's extra speed |
| Reverse | Limit `reverse_max_speed_kph`, or with 0 the game's `Script.maxSpeedReverse / 1.5` (script 40 ≈ 26.7 km/h). Full force below it, none at or above. `reverse_governor_start_fraction` < 1 gives a smooth fade. |
| Reverse, Sunday Driver | Force × 0.70, and × max(0, (15 − 1.5 × speed) / 10) once 1.5 × speed exceeds 5 km/h, so zero at 10 km/h |

These limit propulsion only. A slope or a push can still make the vehicle faster.

### RPM and gears

RPM is estimated from speed; wheel speed is not measured:

```text
rpm in gear g = speedKph / maxSpeed × redline × ratio(g)
ratio(g) = gear_ratio_span ^ ((gearCount − g) / (gearCount − 1))   (first = span, top = 1)
reverse rpm = min(1, speedKph / reverseLimit) × redline × 0.90
```

The model aims at the larger of that and `idle + throttle × (launch − idle)`, clamped to
redline × 1.05 forward or × 0.90 reverse, with a first-order lag of `rpm_response_seconds`.

| Family | Redline key (default) | Torque peak key (default) |
| --- | --- | --- |
| `generic` | `generic_redline_rpm` (5500) | `generic_torque_peak_fraction` (0.50) |
| `van`, `jeep` | `utility_redline_rpm` (4500) | `utility_torque_peak_fraction` (0.40) |
| `firebird` | `sport_redline_rpm` (6500) | `sport_torque_peak_fraction` (0.65) |

After a shift no other shift happens for `shift_hold_seconds`.

- **Up** when moving faster than 0.5 m/s, RPM above redline × `upshift_rpm_fraction`, and the
  next gear stays at or above `launch_rpm`.
- **Down** when RPM is below redline × `downshift_rpm_fraction` or below redline ×
  `demand_downshift_fraction` while demand is above 0.8 (the accelerator held, not cruise control), and only if the
  lower gear stays below redline × min(0.90, upshift − `shift_hysteresis_fraction`).
- `low_mode` (developer) uses 0.96 as the upshift fraction and prefers lower gears, but cannot
  over-rev.

### Direction changes

The game decides forward, reverse or braking before the hook runs. When the requested direction
differs from the model's, the model drops throttle and force, sets idle RPM and gear 1, and
returns `DIRECTION_HOLD` until the vehicle has stayed slower than `direction_speed_mps`
(0.15 m/s) against the new direction for `direction_hold_seconds` (0.15 s). The update that
completes the wait still applies no force. Raw key state is not changed.

Each applied step clears `wasUsingParkingBrakes`, so a later fallback cannot apply the game's
×8 boost for releasing the parking brake a second time.

### Offroad

On an applied offroad step the factor is `offroadEfficiency × 0.6` (× 0.8 instead of 0.6 when
towing), and `OWN_OFFROAD` skips the game's gear-dependent penalty for that step only. A
declined step keeps the game's penalty. Tyre and rain friction stay the game's.

## Keyboard steering

The steering response stays the game's (`SteeringModel`). Per update, with
`m = GameTime.getMultiplier() / 0.8` and `f = max(0.1, 1 − speed / maxSpeed)`:

```text
key held:     steering −= (input + steering) × 0.06 × m × f
key released: steering moves towards 0 by 0.04 × m (to 0 within 0.04)
```

What changes is how key time is counted. The game reads the keyboard once per frame, so a tap
counts as a whole number of frames. With `steering_precise_input` on (default), a key timeline
measures how much of each update the bound Left and Right keys were really down, and the model
applies the game's step for that share: share 1 is the game's step, 0 is its return, and two
half updates equal one whole.

### Measured key time

- `KeyTimeline` (in the extension runtime, `pztools.extensions.runtime.input`) polls on its own
  daemon thread every 0.5 ms requested, about 1 ms in practice, and keeps running totals.
  `WindowsKeys` reads `GetAsyncKeyState` through the JDK's foreign-function interface with a
  private high-resolution waitable timer. Keys count only while the game window is in front.
  It installs no hook, injects no input and loads no native library of its own. The game's JVM
  already runs with `--enable-native-access=ALL-UNNAMED`, so no warning appears.
- `SteeringKeys` matches the timeline to the game's current bindings and replaces it when they
  change. A timeline nobody read for 2 seconds is stopped and restarted on demand.
- When the game accepts steering keys right now (`steeringInputOpen`: keyboard control, working
  vehicle, movement not blocked, no text entry, not drunk), the measured time is the input
  (`steering_timing=direct`).
- Otherwise measured time is spent only once the game's own `ClientControls` reports that
  direction (`HeldInput`, `confirmed`). Time waits up to 3 updates for confirmation; 6 updates
  of disagreement drop the measurement. Drunk input goes this way because the game delays it by
  a random time.
- **After a release**, the unheld rest of that update is not returned in it. The steering stays
  where it is and the return is carried into the next update. Physics sees only the value an
  update ends with, so returning at once would make a short tap vanish depending on where in
  the frame it ended. Unheld time before a press is returned first, in the same update.

Measured time is dropped for an update, and the game's whole-update step used
(`steering_timing=frame`), when the bindings cannot be read, carry a modifier or name a mouse
button, the platform part cannot be opened, the polling thread had a gap over 5 ms, or it is the
first update after such a gap.

### A late key release

The game runs physics before it refreshes `ClientControls`, so a released direction can linger
for one update. For keyboard vehicles the extension reads `GameKeyboard.isKeyDown("Left")` and
`("Right")` and treats a direction whose key is no longer down as neutral. It never creates a
press or a reversal and never writes `ClientControls`.

## Light around the vehicle

The game lights a vehicle's surroundings in one case, a lightbar: `BaseVehicle.updateWorldLights`
registers an `IsoLightSource` with `IsoCell.addLamppost` and moves it tile by tile. The
extension does the same with its own light (`VehicleControl.gameFrame`), from the per-frame
tick, because the physics hook stops for a parked vehicle.

- **When.** The first local player who is in a vehicle (any seat) decides. The light exists
  while that vehicle's `getHeadlightsOn()` and `getHeadlightCanEmmitLight()` are both true, so a
  flat battery or broken bulbs mean no light.
- **Where.** On the vehicle's tile. It moves when the tile changes, at most every 50 ms,
  because each move makes the game relight the area.
- **What.** One steady light (`life = -1`; other values make the game fade it), colour
  brightness × (1, 0.95, 0.85), radius `area_light_radius` (3–20 tiles, rounded, default 8),
  brightness `area_light_brightness` (0.1–1.0, default 0.6).
- **Removal.** On the game thread through `removeLamppost`. Turning off, disconnecting and
  faults happen on other threads, which must not call into the game, so they set `life = 0`
  and the game drops the light on its next lighting pass.
- **Isolation.** If the lighting accessors are missing or placing a light throws, only the light
  stops for that activation (`area_light=unavailable` or `failed:…`). Driving carries on.

`probe_only` places no light.

## Turning off

Switching the extension off sends `OFF`, which does not wait for the safe point. The slot
revokes the generation at once: the hooks are unregistered, so the next call runs the game's
code; the key thread stops; the light is expired. Calls in flight get up to 5 seconds, then
the transformer is removed and the class retransformed back. Values already written into an
update in progress stay, and movement, collisions and fuel already used are not undone.

Turning a single option off is a configuration change and waits for the safe point.

The same release happens when the control connection ends (PZ Tools closes), when the lease
lapses (5 seconds without a command), when the world changes and after a fault. After a fault the scheduler also
saves the extension as off, so the game's own control stays until the player turns it on again.

## What is never written

- **Game files.** Classes are changed in memory only.
- **Saves.** The extension calls no save routine. The light is an in-memory lamppost entry, not
  part of any saved object, and ends with the world. Driving writes only the live fields listed
  under [the four options](#the-four-options), which the game itself rewrites every frame.
- **Shared data.** `VehicleScript` objects are only read. `ClientControls` and key state are
  never written; no input is injected.
- **Settings.** They stay in PZ Tools' own folders ([tuning](#tuning)); the game side receives
  them as a map with `APPLY` and never reads or writes a file.

## Tuning

| File | Role |
| --- | --- |
| [config/game-extensions/vehicle-drivetrain.toml](../../config/game-extensions/vehicle-drivetrain.toml), deployed to `game-bridge/extensions/` | Defaults and the allowed range of every key, in comments |
| `%LOCALAPPDATA%/PzTools/config/vehicle-drivetrain/default.toml` (`VehicleDrivetrainConfiguration.OverridePath`) | Optional overrides, same flat keys. Beside the other editable files, so Apply settings checks it (`AppSettingsService.ValidateEditableConfiguration`) and Restore default settings sets it aside. Moved once from `extensions/vehicle-drivetrain.toml`, where versions before 0.2.4 read it |
| `settings.json` | The four switches; they override both TOML files, including before the first save |

`VehicleDrivetrainConfiguration.Load` (C#) layers the files, rejects unknown keys, wrong types,
duplicates and out-of-range values, and accepts and ignores six retired `steering_*` rate keys.
It also checks: upshift − downshift ≥ 0.15; `idle_rpm` < `launch_rpm` < every redline;
`launch_rpm` ≤ lowest redline × upshift / √`gear_ratio_span`; `reverse_max_speed_kph` 0 or
4–35. The flat result is sent with `APPLY`; the game side validates it again
(`DrivetrainConfig`, `VehicleControl.Settings`) and never reads a file. A file that fails is
`configuration-rejected`, and the scheduler turns the extension off.

The ranges exist twice: `Numbers` in `VehicleDrivetrainConfiguration.cs` and
`DrivetrainConfig.java`. Change both.

Developer keys, not on the card: `low_mode`, `probe_only` (observe without writing anything;
diagnostics show one-step predictions), `diagnostics_enabled`, `steering_precise_input`.

Fixed constants:

| Constant | Value | Where |
| --- | --- | --- |
| Nominal force for the forward ramp rate | 0.65 × enginePower | `DrivetrainModel.NOMINAL_GAME_FORCE` |
| Traits, offroad, governor margin | 0.75 / 0.70, 0.6 / 0.8, +20 km/h, × 1.15 | `DrivetrainModel` |
| RPM ceiling | redline × 1.05 forward, × 0.90 reverse | `DrivetrainModel.step` |
| Output bounds | force ≤ 1,000,000, RPM ≤ 7000 | `VehicleControl.tryControl` |
| Steering | 0.06, 0.04, minimum speed factor 0.1, held share ≤ 4 | `SteeringModel` |
| Confirmation | 3 updates, 6 for mismatch | `HeldInput` |
| Key polling | 0.5 ms requested, 5 ms gap tolerance, 2 s idle stop | `KeyTimeline`, `SteeringKeys` |
| Light | 50 ms between moves, colour ratios | `VehicleControl` |
| Safe point | 0.5 km/h, throttle 0.01 | `VehicleAccess.ready` |
| Profiles | 3–5 gears, top speed 20–300 km/h | `VehicleProfile.resolve` |

## Replacement and failure handling

[Component updates](module-reload.md) describes replacement in general. For this module:

- **Checks first.** A new archive is loaded, its configuration validated and its preflight run
  against the current class before the healthy generation is retired. A failure leaves the
  current generation running and reports `update-rejected:…`; the scheduler then turns that
  request off.
- **Failure while installing.** If `initialize` fails after the old generation was retired, the
  slot reports `Unsupported` with no generation, and the game's own control runs.
- **Unclear retirement.** If calls in flight do not drain within 5 seconds or cleanup throws,
  the state becomes `RestartRequired` for the rest of the game process.
- **Order.** New calls are refused before waiting for calls in flight. Cleanup never waits for
  a game update and never holds a lock a call in flight needs.
- **Other transformers.** Only this module's transformer is removed.

## Diagnostics

With `diagnostics_enabled`, `STATUS` carries the latest sample and one-second summaries
(`VehicleControl.diagnostics`): mode, outcome, reason, gear, RPM, `requested_force`, speed,
`throttle` (the model's pedal), `demand` (the game's), native arguments, callback timings, steering
fields (`steering_precise`, `steering_timing`, `steering_held_share`, `steering_keys`) and
`area_light`. The app writes the sample to the **Logs** page with each `extension.runtime.changed`
entry (a change of the extension's state) and, while the state stays the same, as an
`extension.runtime.sample` entry when the sample is newer, at most once every 10 seconds
(`ExtensionRuntimeDiagnostics.SampleInterval`). Sample entries are always information, whatever the
state's own level. `sample_age_ms` says how old a sample was. `native_*` are the arguments just
before the native call, not proof that it succeeded. Callback timings leave out the game's own
code and are not a frame cost.

## Tests

`DrivetrainModelTest`, `SteeringModelTest`, `KeyTimelineTest`, `VehicleHooksTest`,
`VehicleAdapterBehaviorTest`, `VehicleCompatibilityTest` (Java, against fixtures in
`tests/vehicle-drivetrain-fixture/`), and `VehicleDrivetrainConfigurationTests` (C#). Game code
is never copied into fixtures.

## References

The design drew on [Better Car Physics](https://steamcommunity.com/sharedfiles/filedetails/?id=2909035179),
[BVD at d96dea6](https://github.com/grphx/better-vehicle-dynamics/blob/d96dea603c1c1665c486e3a0ed5bad16e2d23366/mods/better-vehicle-dynamics-42/patches/zombie/core/physics/CarController.java.patch)
and [TVP at a3c28b2](https://github.com/pocket120/True_Vehicle_Physics_B42_Project_Zomboid/blob/a3c28b24c90beaf74cf3e589027e19c7f56c36ae/TrueVehiclePhysics/Contents/mods/truevehiclephysics/42/media/lua/shared/TrueVehiclePhysicsTransmission.lua).
