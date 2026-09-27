# Vehicle drivetrain design

[Documentation index](README.md) · [User guide](../README.md)

The `pztools.vehicle-drivetrain` module is an experimental, default-off extension. Version 0.2.0 implements independent forward acceleration/transmission, reverse, and keyboard-steering controls. Pure-model, synthetic-adapter, and separate-JVM checks exist; real driving, native force/time calibration, fuel/noise effects, and in-game reload acceptance remain open. Use the [vehicle test guide](e2e-vehicle-drivetrain.md) for hands-on validation.

## Scope and compatibility

The goal is smoother reacceleration, shifting, reverse launch, and keyboard steering while retaining differences between vehicles. The module does not replace mass, cargo, tire friction, suspension, collision, ordinary braking, character traits, or gamepad steering.

The catalog declares major version 42. Activation checks the exact field types, method signatures and static/instance access used by the adapter, then validates the actual bytes received by the JVM transformer. It does not require whole-class hashes for `WorldSimulation`, `GameTime`, `BaseVehicle` or the other surrounding classes to match. The inspected installation JAR had SHA-256:

```text
80E405A4BFC42F6072E75B3735F458A6514143DA011D3226007DED305A442F44
```

That is a research baseline, not a Steam-original authenticity check or a promise of support for every B42 patch. Research artifacts remain local under the ignored `artifacts/vehicle-physics-research/`; game classes and decompiled sources are not distributed.

The three control methods and the steering and offroad blocks whose execution can be skipped retain narrow, normalized bytecode contracts. Changes to their instructions, constants, calls or branch targets require review because the adapter could otherwise omit new game or mod behavior. Constant-pool layout, method order, debug metadata and NOPs do not affect these contracts. The surrounding `update` layout is checked for call sites, control-flow boundaries and required fields; unrelated members are allowed. Each retransformation is checked again, and a conflict releases the extension's control without replacing another transformer's output with a disk copy.

From dispatch through the braking decision, every path must pass the original mode guards and back-signal update in order. Early exits, skipped checkpoints, exception handlers and cycles or re-entry across that phase are rejected. The braking guard is checked even though the braking implementation is not replaced: direction-change hold relies on that original call. Original conditional branches and unrelated code outside this protected phase remain eligible.

Passing these checks establishes patch compatibility, not equivalent driving behavior. External changes to physics stepping, input sampling or friction still need combined in-game testing. A version override does not bypass these contracts.

Propulsion requires a local single-player driver, a running engine, four wheels, valid script values, and a supported engine family: `generic`, `van`, `jeep`, or `firebird`, with 3–5 gears. Being towed, burnt vehicles, and towing a burnt vehicle use original propulsion. Ordinary towing remains a driving-test case. Unknown profiles fall back rather than guessing a physical model.

Keyboard steering has a separate eligibility check. It can operate with the engine off or an unsupported propulsion profile, but gamepad, multiplayer, towed, and burnt-vehicle steering remains original.

The extension transforms selected Java call sites in memory; installation files are unchanged. Compatibility with other vehicle-physics patches is not guaranteed. The version-range override bypasses only the declared range; structural and ownership checks still apply. Disabling returns control to the game but does not undo movement, collisions, or fuel already consumed.

## Why the adapter uses these call sites

Inspection of the target build found that `CarController.update` calls `control_ForwardNew`, not the older `control_Forward`. Forward, reverse, coasting, and braking have distinct RPM/gear behavior. Tire-loss and offroad adjustments occur later, before the original `Bullet.controlVehicle`, engine-start, and non-running-engine handling.

The adapter therefore guards the resolved control calls inside `update`. It does not replace the full class, intercept every caller of a private control method, or add a second native force call. Existing cruise, intoxication delay, unloaded-chunk braking, signals, and engine-start decisions stay in their original order.

The inspected game also uses gear/RPM for fuel and sound. The module writes one shared gear/RPM state for control and display; it does not maintain a separate display-only RPM. Fuel consumption, engine sound, zombie attraction, and animal reactions consequently belong in acceptance testing.

## Current numerical model

Inputs use seconds, signed longitudinal m/s, RPM, and throttle in `[0,1]`. Output is in the game's force-input units. Script wheel radius is validated, but is not assumed to be meters. There is no claim of measured wheel torque, Newtons, or real-world horsepower.

### Forward and reverse force

Forward force starts from the inspected game's base envelope:

```text
enginePower × firstGearFactor × (0.3 + RPM / 30000)
            × clamp(1 - speedKph / 200, 0, 1)
```

`firstGearFactor` is `1.5 × low_gear_boost` in first gear or below `maxSpeed / gearCount`; otherwise it is 1. This preserves the original low-speed force range when the RPM proxy shifts early. The default `low_gear_boost` is 1.

The torque-curve modulation is `1 + forward_torque_boost_fraction × torqueShape(RPM)` times that base envelope. The setting accepts 0–0.10 and defaults to 0.10, preserving the existing 1.0–1.1 range. Zero removes only this RPM-dependent boost; it does not disable the extension's shifting or pedal response. This does **not** bound the change in total vehicle performance to 10%: the RPM/gear trajectory differs, and the original additional forward fade above 6,000 RPM is not reproduced. Candidate gear ratios guide RPM and shifting; they do not apply another `ratio(current)/ratio(first)` force penalty.

Reverse uses the inspected reverse envelope:

```text
enginePower × (0.75 + RPM / 24000) × clamp((7000 - RPM) / 1000, 0, 1)
```

The default `reverse_force_ratio=1` adds no further settled-force reduction. Throttle and delivered force both rise over the default 0.8-second reverse ramp; forward uses 0.3 seconds. Direction changes reset the ramp so inherited RPM cannot create a first-tick force spike.

Each path applies `force_scale`, throttle, trait effects, and its single offroad factor once. Stored `enginePower` already includes generation-time quality adjustment; quality is not multiplied again. Force is not increased with current cargo mass, and mass is not re-added.

### Speed limits and traits

The forward governor fades from `M` to `M+20` km/h, where `M=maxSpeed`, or `maxSpeed×1.15` for Speed Demon. It does not use `(maxSpeed+20)×1.15`. Sunday Driver preserves the inspected output factors and additional speed fade, including a factor that can briefly exceed one just above its original threshold; negative propulsion is prevented.

Default `reverse_max_speed_kph=0` uses `Script.maxSpeedReverse / 1.5`, matching the original reverse speed conversion. A raw value of 40 therefore corresponds to about 26.667 km/h. Explicit overrides accept 4–35 km/h; values strictly between 0 and 4 are rejected. Default `reverse_governor_start_fraction=1` adds no fade before the limit and sets propulsion to zero at it; lower developer values retain a soft fade.

Sunday Driver applies reverse output ×0.70 and the original additional speed factor, reaching zero propulsion at 10 km/h. These are propulsion limits, not forced velocity clamps: slopes or external forces can still carry a vehicle faster.

### RPM, shifting, and direction changes

Profiles use geometrically spaced candidate ratios and a speed-based RPM proxy, not measured wheel angular velocity. Upshifts require speed, RPM, and acceptable destination RPM. Downshifts consider reduced speed or high demand and reject over-revving destinations. Separate thresholds, hysteresis, and a minimum hold time reduce gear hunting; developer low mode cannot override over-rev protection.

Original `NoControl` and `Braking` remain responsible for coasting and braking, including their gear/RPM changes. On every return to original control, temporary decline, driver change, or missed frame, the model invalidates its dynamic state. Re-entry reconstructs a safe gear from current speed and starts with fresh force/throttle state instead of reviving a stale high gear or accumulating elapsed time.

The game resolves forward/reverse/braking intent before the module runs. Opposite residual motion produces `DIRECTION_HOLD`: the adapter sets the resolved braking mode and associated gas/brake flags, then uses the original braking and signal path exactly once. Changing direction requires remaining near a stop for 0.15 seconds by default. The sample that completes this wait still applies zero force. Raw keys are unchanged.

Successful propulsion consumes the original parking-brake-release boost event so a later fallback cannot replay its ×8 force boost.

### Offroad and steering

On a successful offroad propulsion step, the model replaces only the old gear-number-dependent force penalty. Its single factor uses validated script efficiency and the existing 0.6 baseline, or 0.8 when towing. The per-update `OWN_OFFROAD` flag skips the original penalty only for that successful step. Declined steps keep the original penalty. Native tire/rain friction, suspension, and collision remain intact; shared `VehicleScript` objects are read-only.

Extra engine braking is not implemented. Original coasting remains in use until native deceleration and force semantics are measured.

Keyboard steering is an independent phase immediately before the original interpolation block. It uses the already-processed input, replaces that interpolation when eligible, and preserves downstream angle clamps, tire processing, wheel display, and native calls.

The game runs physics before refreshing `ClientControls`, so the previous steering direction can remain for one update. For keyboard-controlled vehicles only, the adapter checks the game's mapped `GameKeyboard.isKeyDown("Left"/"Right")` input and suppresses an already-released direction to neutral. It never creates a new press or reversal, modifies `ClientControls`, or restores input suppressed by the game's intoxication, aiming, loading, or text-input gates. New input remains subject to the original game path.

A repeated callback in the same frame reuses an already-applied pre-tire steering value without another model integration or vanilla interpolation. This avoids cumulative downstream tire correction. Observation-only predictions and declined steps never create an applied cache; invalid input, driver changes, and reconfiguration invalidate it.

The defaults are an initial rate of 1.8, sustained rate of 7.5, and a 0.1-second ramp, expressed as fractions of maximum steering angle per second. First-input response scales from 1.0 to 0.6 with speed. Return and countersteer rates are both 8; the countersteer floor follows the latest held intent through center, including rapid repeated reversals.

With a fixed angle cap, the theoretical default timings are approximately 171–260 ms center-to-lock, 125 ms lock-to-center, and 250 ms lock-to-opposite-lock. These are model calculations, not measured game latency.

## Adapter and hot-path contract

`VehicleHooks.tryControl` runs once for resolved propulsion and separately for steering. Each callback acquires one generation/configuration, reads inputs, computes and validates output, commits, and releases the generation.

| Outcome | Behavior |
| --- | --- |
| `VANILLA` | Invalidate applicable model state and execute original control |
| `APPLIED` | Commit validated fields and skip that original calculation |
| `DIRECTION_HOLD` | Commit no propulsion fields; continue through original braking with adjusted resolved flags |
| `OWN_OFFROAD` | Additional flag valid only on the same successful propulsion step |

All handles, receiver types, gear objects, and output values are validated before the first field write. Commit uses prepared field access and does no I/O, Lua calls, reflective discovery, or allocation. A partial write followed by fallback is not a permitted recovery strategy. Module exceptions or invalid outputs close admission before subsequent callbacks rather than retrying each frame.

Per-update flags are local; previous vehicle/tick success cannot grant a bypass. Retirement cannot undo fields already committed into an in-flight game update, and the next generation cannot overwrite that update.

Time comes from the game's physics-time interface and is validated in seconds. Invalid, zero, or excessive dt falls back; default maximum dt is 0.1 seconds. Duplicate propulsion and wrong-thread entry are declined. Same-frame steering reuses a validated, already-applied value for the same driver; all other duplicate steering cases retain the original-control fallback. Pause/resume does not trigger an unbounded catch-up loop. The relationship between controller calls and native 0.01-second physics substeps still requires live measurement.

Vehicle profiles and scratch state are cached, with weak references for vehicle/driver ownership. The steady-state target is no per-tick allocation, configuration parsing, reflection lookup, IPC, or waiting. The module processes the local driver rather than scanning all world vehicles.

## Configuration and runtime ownership

Defaults and ranges live in [vehicle-drivetrain.toml](../config/game-extensions/vehicle-drivetrain.toml). User overrides use `%LOCALAPPDATA%/PzTools/extensions/vehicle-drivetrain.toml`. .NET and Java validate an immutable configuration before application; the game callback never reads TOML.

The three typed UI preferences override their TOML transport defaults, including before the first JSON save. The extension is initially off, while new feature preferences are all on. Legacy `probeOnly=true` preferences are read as all three features off without rewriting the file merely on read. Low mode, observation, diagnostics, and numerical tuning remain developer-only TOML options.

Saved intent and JVM application are separate. The UI keeps controls editable offline or while waiting for a safe boundary; detailed revisions, hashes, and transition reasons go to logs. Confirmed failure turns off only the matching request through compare-and-swap, without overwriting a newer user choice.

[RuntimeExtensionCoordinator](../src/PzTools.State.Scheduler/RuntimeExtensionCoordinator.cs) owns the authenticated control connection, heartbeat, configuration delivery, and reconnection, sharing the existing game-process selection. No or multiple eligible games postpone activation. Save, WATCH, and continuous vehicle control use separate capabilities/slots.

The delivered module is `pztools-vehicle-drivetrain.jar`, capability `vehicle.drivetrain.v1`. Current contracts are bootstrap API10, extension host ABI3, extension-control wire1, save wire6, and WATCH STATE4. The optional save extension is not distributed; when backup requests a game save, the normal path calls `GameWindow.save(true)`. Existing API9-or-earlier resident agents require one full game restart to obtain the new bootstrap contract.

Control requests carry command identity, controller epoch, process/world identity, and expected revision. Retries are idempotent, queues/caches are bounded, and a new controller cannot take over a live owner. Activation/configuration waits for a game-thread safe boundary: vehicles stopped, throttle released, and cruise disabled. Explicit deactivation, disconnect, fault, and lease expiry can close callback admission without waiting for a game tick. The control lease is five seconds.

On disconnect, the session revokes admission immediately and retains lifecycle ownership until its in-flight host calls and retirement finish. Late callbacks and repeated close requests are inert. Game-thread polls use a non-blocking session gate, so commands and retirement never make the game thread wait for that gate.

State is scoped by process, world, module generation, vehicle, and driver; reused numeric vehicle IDs cannot revive it. Exit, world changes, retirement, and fault release references. A fault returns to original control and requires an explicit new activation/configuration or module candidate before revalidation.

## Replacement and failure handling

Archive, ABI, configuration, and bytecode preflight occur before retiring a healthy generation. A preflight rejection leaves it installed and reports `update-rejected`; app policy can then safely turn off the matching failed request. An installation-stage failure may leave original control rather than restore the old generation. Uncertain retirement or drain timeout sets `RestartRequired`, which reconnecting or changing worlds must not clear.

Admission closes before drain. Cleanup must not wait for a game tick that dispatch has already paused, or hold a lock needed by an in-flight callback. Only this module's transformer is removed; retransformation must not overwrite other agents with bytes reread from disk.

Replacement preflight distinguishes live pre-hook input from this module's output and checks later Java transformers present in that pass. Installation validates again. These checks cannot prevent later transformer registration or changes made through native/JVMTI transformers or JNI. Repeated reload tests must distinguish the module's own prior hooks from actual external conflicts.

## Validation and remaining acceptance

Automated checks cover finite/bounded model outputs, direction transitions, timestep variation, shift hysteresis, steering reversals, adapter field/native-argument results, fallback equivalence, lifecycle drain, configuration revisions, and repeated replacement. Installed-JAR checks read the user's JAR in a separate inert JVM; game code is not copied into fixtures or distributed.

Diagnostics are opt-in, latest-sample plus one-second aggregates. `requested_force` in observation mode is a reset, one-step prediction. `native_force/brake/steering` are arguments immediately before the original native call, not proof of native success. Callback timings exclude original/native execution and must not be presented as total frame cost.

Remaining live acceptance includes native force/radius/time meaning, road and offroad behavior, loaded and towing vehicles, reverse launch, steering feel, fuel/noise effects, frame-rate variation, and save/WATCH/reload coexistence. Numeric performance targets require a vanilla baseline; neither FPS gains nor universal mod support follow from synthetic tests.

Design references: [Better Car Physics](https://steamcommunity.com/sharedfiles/filedetails/?id=2909035179), [BVD at d96dea6](https://github.com/grphx/better-vehicle-dynamics/blob/d96dea603c1c1665c486e3a0ed5bad16e2d23366/mods/better-vehicle-dynamics-42/patches/zombie/core/physics/CarController.java.patch), and [TVP at a3c28b2](https://github.com/pocket120/True_Vehicle_Physics_B42_Project_Zomboid/blob/a3c28b24c90beaf74cf3e589027e19c7f56c36ae/TrueVehiclePhysics/Contents/mods/truevehiclephysics/42/media/lua/shared/TrueVehiclePhysicsTransmission.lua).
