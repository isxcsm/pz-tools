# Vehicle driving extension: design

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

**Vehicle driving improvements** (`pztools.vehicle-drivetrain`, version 0.2.0) is an
experimental [game extension](game-extensions.md), off by default. It has four options,
each with its own switch:

- **Natural acceleration and shifting**: smoother pull-away, re-acceleration and gear
  changes going forward
- **Smooth reversing**: a gentler reverse launch and a cleaner change of direction
- **Precise keyboard steering**: steering that follows how long a key is actually held
- **Light around the vehicle**: a glow on the ground around the vehicle while its
  headlights are on

This page explains how each works and how the extension attaches to the game. To try
it in a real game, use the [vehicle test guide](e2e-vehicle-drivetrain.md).

**Status.** The driving model, the adapter against a synthetic game and checks in a
separate Java process are tested automatically. Real driving has not been accepted
yet: what the game's force and time values mean physically, the effect on fuel and
noise, and updating the module inside a running game still need live testing.

## What it changes and what it leaves alone

The aim is smoother acceleration, shifting, reversing and keyboard steering, while
vehicles still feel different from one another.

It does **not** change mass, cargo, tyre grip, suspension, collisions, ordinary
braking, coasting, character traits or gamepad steering. It adds no extra engine
braking: the game's own coasting stays until its deceleration is measured.

**When forward and reverse control apply.** The driver is the local single-player
player, the engine is running, the vehicle has four wheels and valid script values,
and its engine family is `generic`, `van`, `jeep` or `firebird` with 3–5 gears. In
every other case the game's own propulsion is used: an unknown engine profile, a
vehicle being towed, a burnt vehicle, or towing a burnt one. Ordinary towing is
allowed and is one of the things to test.

**When keyboard steering applies.** Steering is checked separately. It also works
with the engine off or with an unsupported engine profile. Gamepad steering,
multiplayer, and towed or burnt vehicles keep the game's steering.

**Turning it off** hands control straight back to the game. It does not undo
movement, collisions or fuel already used.

## Limits

- **No physical units.** Inputs are seconds, signed forward speed in m/s, RPM and
  throttle from 0 to 1. The output is in the game's own force units. The wheel radius
  from the vehicle script is checked but not assumed to be in metres. Nothing here is a
  measured wheel torque, a force in newtons or real horsepower.
- **Other vehicle mods.** It is not guaranteed to work together with other mods that
  change vehicle physics.
- **Game updates.** Passing the compatibility checks below means the game code looks
  as expected. It does not prove that driving feels the same, and changes elsewhere in
  physics stepping, input or friction still need testing in the game.
- **Ignoring the version limit** only skips the declared game-version range. Every
  other check still applies.
- **Multiplayer** is not supported by any part of the extension.

## How it attaches to the game

The extension changes a few Java call sites in memory while the game runs. No file of
the game installation is modified.

### Why these call sites

In the inspected build, `CarController.update` calls `control_ForwardNew` (not the
older `control_Forward`). Forward, reverse, coasting and braking each handle RPM and
gear in their own way. Tyre-loss and offroad adjustments come afterwards, followed by
the game's `Bullet.controlVehicle`, engine start and the handling of a stopped engine.

So the extension guards the chosen control calls inside `update`. It does not replace
the whole class, intercept every caller of a private control method, or add a second
native force call. Cruise control, the drunk-driving delay, braking in unloaded
chunks, signals and engine start keep their original order.

The game also uses gear and RPM for fuel and sound. The extension writes one shared
gear/RPM state, used for both control and display; there is no separate display-only
RPM. Fuel use, engine sound, and how zombies and animals react to it therefore belong
in live testing.

### What happens on each game update

`VehicleHooks.tryControl` runs once for propulsion and once, separately, for steering.
Each call takes the current module [generation](glossary.md#generation-module) and
settings, reads the inputs, computes and checks the result, writes it, and releases the
generation. It ends in one of these outcomes:

| Outcome | What happens |
| --- | --- |
| `VANILLA` | The extension's state for this case is cleared and the game's own code runs |
| `APPLIED` | The checked values are written and that piece of the game's calculation is skipped |
| `DIRECTION_HOLD` | No propulsion is written; the game's braking path runs with adjusted flags (see [direction changes](#rpm-shifting-and-direction-changes)) |
| `OWN_OFFROAD` | An extra flag, valid only on the same successful propulsion step (see [offroad](#offroad)) |

Rules for this code, which runs every frame:

- **All or nothing.** Every handle, type, gear object and output value is checked
  before the first field is written. Writing part of the result and then falling back
  is not allowed.
- **Nothing slow.** Writing uses prepared field access: no file access, Lua calls,
  reflection lookups or memory allocation. In steady driving the target is no
  allocation, settings parsing, reflection, inter-process calls or waiting per update.
  Vehicle profiles and scratch state are cached, with weak references to the vehicle
  and driver. Only the local driver's vehicle is processed; the world is not scanned.
- **A fault stops it.** An exception or invalid output closes the module to further
  calls, rather than failing again every frame.
- **Nothing carries over by accident.** Per-update flags are local, so success on an
  earlier update or another vehicle cannot allow a skip now. Retiring the module cannot
  undo values already written into an update in progress, and the next generation
  cannot overwrite that update.
- **Time.** The time step comes from the game's physics time and is checked in
  seconds. A missing, zero or too large step (over 0.1 seconds by default) falls back
  to the game. Pausing and resuming does not cause a catch-up burst.
- **Duplicates.** A second propulsion call in the same update, or a call on the wrong
  thread, is declined. A second steering call in the same frame reuses the value
  already applied for the same driver (see [repeated calls](#repeated-calls-in-one-frame));
  any other duplicate steering call falls back.

How the controller's calls relate to the game's native 0.01-second physics substeps
still has to be measured in the game.

### Compatibility checks against the game build

The [catalogue](../config/game-extensions/catalog.tsv) declares game version 42. Before
the extension starts, it checks the exact field types, method signatures and
static/instance access it uses. Then it checks the actual bytes the Java runtime hands
to its transformer. Whole-class hashes of `WorldSimulation`, `GameTime`, `BaseVehicle`
and the other surrounding classes do not have to match.

The code the extension can skip is checked more strictly: the three control methods,
and the steering and offroad blocks. Their instructions, constants, calls and branch
targets must match. A change there needs review, because skipping it could silently
drop new game or mod behaviour. Constant-pool layout, method order, debug information
and no-op instructions do not matter. In the surrounding `update` method only the call
sites, control-flow boundaries and required fields are checked; unrelated members may
change.

From dispatch up to the braking decision, every path must pass the game's own mode
checks and the back-signal update, in order. Early exits, skipped checkpoints,
exception handlers, loops and re-entry within that stretch are rejected. The braking
check is required even though braking itself is not replaced, because holding on a
change of direction relies on that original call. Conditional branches of the game,
and code outside this stretch, may differ.

Each later retransformation is checked again. If another transformer conflicts, the
extension gives up control; it never replaces the other transformer's output with a
copy read from disk.

The research baseline was a game JAR with this SHA-256:

```text
80E405A4BFC42F6072E75B3735F458A6514143DA011D3226007DED305A442F44
```

It is a reference point, not a check that a game is an unmodified Steam copy and not a
promise that every Build 42 patch works. Research files stay local in the ignored
`artifacts/vehicle-physics-research/` folder. Game classes and decompiled sources are
never distributed.

## The driving model

### Forward force

Forward force starts from the game's own base curve:

```text
enginePower × firstGearFactor × (0.3 + RPM / 30000)
            × clamp(1 - speedKph / 200, 0, 1)
```

`firstGearFactor` is `1.5 × low_gear_boost` in first gear or below
`maxSpeed / gearCount`, and 1 otherwise. This keeps the game's low-speed force even
when the extension's RPM estimate shifts up early. `low_gear_boost` defaults to 1.

On top of that the force is multiplied by `1 + forward_torque_boost_fraction ×
torqueShape(RPM)`. The setting accepts 0–0.10 and defaults to 0.10, the same 1.0–1.1
range as before. Zero removes only this RPM-dependent boost; shifting and pedal
response still work.

This does **not** limit the overall change in performance to 10%: the RPM and gear
path differs from the game's, and the game's extra fade above 6,000 RPM is not
reproduced. The candidate gear ratios steer RPM and shifting only; they do not apply a
further `ratio(current)/ratio(first)` force penalty.

### Reverse force

Reverse uses the game's reverse curve:

```text
enginePower × (0.75 + RPM / 24000) × clamp((7000 - RPM) / 1000, 0, 1)
```

The default `reverse_force_ratio = 1` reduces it no further. Throttle and force both
rise over a ramp: 0.8 seconds for reverse by default, 0.3 seconds for forward. A change
of direction restarts the ramp, so RPM left over from before cannot cause a spike on
the first update.

### Applied to both directions

`force_scale`, throttle, trait effects and one offroad factor are each applied exactly
once. The stored `enginePower` already includes the vehicle's quality from when it was
generated, so quality is not applied again. Force does not grow with current cargo, and
mass is not added again.

### Speed limits and traits

- **Forward.** Force fades out between `M` and `M + 20` km/h, where `M` is `maxSpeed`,
  or `maxSpeed × 1.15` with the Speed Demon trait (not `(maxSpeed + 20) × 1.15`).
- **Sunday Driver, forward.** The game's output factors and extra speed fade are kept,
  including a factor that can briefly go above one just past the game's threshold.
  Propulsion never turns negative.
- **Reverse.** The default `reverse_max_speed_kph = 0` means the game's own limit,
  `Script.maxSpeedReverse / 1.5`: a script value of 40 is about 26.667 km/h. An
  explicit value must be 4–35 km/h; anything between 0 and 4 is rejected. The default
  `reverse_governor_start_fraction = 1` means no fade before the limit and zero
  propulsion at it; lower developer values give a soft fade.
- **Sunday Driver, reverse.** Output ×0.70 plus the game's extra speed factor,
  reaching zero propulsion at 10 km/h.

These limit propulsion; they do not clamp speed. A slope or an outside force can still
make the vehicle go faster.

### RPM, shifting and direction changes

RPM is estimated from speed, using candidate gear ratios per profile that are
geometrically spaced (each a fixed factor from the next); wheel speed is not measured. An upshift needs enough speed and RPM and an
acceptable RPM after the shift. A downshift happens on lower speed or high demand and
is refused if it would over-rev. Separate thresholds, hysteresis and a minimum time in
gear stop the gearbox hunting. The developer low-gear mode cannot override over-rev
protection.

The game's own `NoControl` and `Braking` still handle coasting and braking, including
their gear and RPM changes. Whenever control goes back to the game, a step is
declined, the driver changes or a frame is missed, the model forgets its dynamic
state. When it takes over again, it picks a safe gear from the current speed and
starts force and throttle afresh, instead of reviving a stale high gear or adding up
elapsed time.

The game decides forward, reverse or braking before the extension runs. If the
vehicle is still rolling the other way, the outcome is `DIRECTION_HOLD`: the extension
sets the game's braking mode and the matching gas and brake flags, then lets the
game's braking and signal code run exactly once. Changing direction requires staying
near a stop for 0.15 seconds by default, and the update that completes the wait still
applies no force. The raw key state is not changed.

When propulsion succeeds, the game's one-off boost on releasing the parking brake is
used up, so a later fallback to the game cannot apply its ×8 boost again.

### Offroad

On a successful offroad propulsion step, the extension replaces only the game's
penalty that depends on the gear number. Its single factor uses the script's checked
offroad efficiency and the game's 0.6 baseline (0.8 when towing). The `OWN_OFFROAD`
flag skips the game's penalty for that step only; a declined step keeps it. Tyre and
rain friction, suspension and collisions stay the game's. Shared `VehicleScript`
objects are only read.

## Keyboard steering

### What the game does, and what changes

Keyboard steering replaces the game's interpolation block, running just before it. It
uses input the game has already processed, and keeps everything after that block: the
angle limits, tyre processing, wheel display and native calls.

The steering response itself stays the game's. Each update the game moves the steering
value by `(input + steering) × 0.06 × m × f` while a key is held, where
`m = GameTime.getMultiplier() / 0.8` and `f = max(0.1, 1 − speed / maxSpeed)`, and
returns it towards the centre by `0.04 × m` when released. The curve, the speed scaling
(down to a tenth at top speed) and the angle limit are not tunable here. Older rate,
ramp, return and countersteer settings are retired and ignored if an old override file
still names them.

What changes is **how key presses are timed**. The game reads the keyboard once per
frame, so a tap counts as a whole number of frames and the same tap gives different
results each time: at 60 Hz a 40 ms tap is two or three frames, and that error falls
on the steepest part of the curve.

### Measured key time

With `steering_precise_input` (on by default), a separate thread polls the bound Left
and Right keys about once a millisecond and keeps running totals. On each update the
extension takes the difference from its previous reading and applies the game's step
for that share of the update. A share of 1 is exactly the game's step, 0 is its
return, and parts add up: two half updates equal one whole one.

So the measured key time is the input, and nothing waits for the game's own look at
the keyboard. However long a frame takes, the next update steers for exactly the time
the keys were held since the previous one. A tap that starts and ends between two
frames still counts, and a press takes effect in the update it happens in, not one
later. Left and right held together cancel, as in the game; within one update,
opposite keys count by their difference.

**Releasing a key.** Physics only sees the value an update ends with, and the game
returns the wheels quickly. If the return started the moment a key was released, a tap
that ended early in an update would be back at centre before anything turned, and how
far would depend on where in the frame it ended. So the unheld time after a release is
not spent in that update. The steering is left where it is, and the return it is owed
is carried into the next update, which spends it first. No return is lost, only
delayed by less than one update, and what a tap leaves behind depends only on how long
it was held. Unheld time *before* a press (the key is down when the update ends) is
returned in the same update, before steering.

**A late key release.** The game runs physics before it refreshes `ClientControls`,
so the previous direction can linger for one update. For keyboard-controlled vehicles
only, the extension checks the game's mapped `GameKeyboard.isKeyDown("Left"/"Right")`
and treats an already released direction as neutral. It never creates a new press or
a reversal, never changes `ClientControls`, and never restores input the game has
blocked (drunk delay, aiming, loading or typing). New input still goes through the
game's own path.

### When the game's own input is followed instead

Whether the game accepts steering keys at all is read from the game on every update,
using the same conditions it applies when it reads the keyboard: a keyboard-controlled,
working vehicle, a local driver whose movement is not blocked, and no text being
typed.

While any of these is not met, or cannot be read, measured time is only spent once the
game's own `ClientControls` reports that direction. Time from up to three updates
earlier is carried over, older time is dropped, and a key already released steers
nothing. The same applies while the driver is drunk, because the game then delays
commands by a random time that only its own input reproduces. A condition added in a
later game build would not be known here; the offline verifier checks these optional
accessors against the installed game.

Measured time is dropped for an update, and the game's whole-update step used, whenever
it cannot be trusted:

- key bindings cannot be read, include a modifier, or are mouse buttons
- the platform part cannot be opened
- the measuring thread stopped or was starved (a gap over 5 ms)
- it is the first update after such a gap

Rebinding a key replaces the timeline; turning the option off stops its thread.
Diagnostics report `steering_precise`, `steering_timing` (`direct`, `confirmed` or
`frame`), `steering_held_share` and `steering_keys`.

### Repeated calls in one frame

A second steering call in the same frame reuses the value already applied before
the tyre step, without running the model or the game's interpolation again. This
prevents the downstream tyre correction from being applied twice. Predictions made
only for observation and declined steps never create such a value; invalid input, a
change of driver and new settings clear it.

### The key timeline

The key timeline (`pztools.extensions.runtime.input`) is a separate part of the
extension runtime with no game dependencies, usable by any extension:

- `KeyTimeline` does the measuring.
- `KeyStateSource` supplies key state and the wait between polls.
- `WindowsKeys` implements it through the JDK's foreign-function interface
  (`GetAsyncKeyState` and a private high-resolution waitable timer).

It only reads key state: no hook, no injected input, no native library of its own.
Keys count only while the game window is in front. The game is launched with
`--enable-native-access=ALL-UNNAMED`, so no warning appears.

### Measurements

On the development machine, with the game's bundled Java 25 runtime:

- polls every 1.0 ms (99th percentile 1.5 ms)
- synthetic taps of 15–180 ms were timed with a mean error of 0.8 ms and a maximum
  of 2.3 ms, against 8 ms and up to 16 ms when read once per 60 Hz frame
- Java's own short waits could not be used: they fell back to the 15 ms system tick

This measures timing, not driving. With a fixed angle limit, the model's default
timings work out to about 171–260 ms from centre to full lock, 125 ms from full lock
back to centre, and 250 ms from one full lock to the other. These are calculations,
not measured game latency.

## Light around the vehicle

The game lights the surroundings of a vehicle in one case: a lightbar.
`BaseVehicle.updateWorldLights` creates an `IsoLightSource` with a radius of 8 tiles and
registers it with `IsoCell.addLamppost`. When the vehicle reaches another tile, it
withdraws that light with `removeLamppost` and registers one on the new tile. The
extension does the same with its own light object and touches nothing else: no
headlight part, no vehicle script, no lighting native.

This adds something the game does not otherwise do, so it has its own switch, separate
from the three driving options. Like them it starts on.

- **When.** Once per game frame, the module looks at the vehicle the local player is
  in. It does this from the frame callback, not the physics hook, which stops firing
  for a parked vehicle. The light exists while `getHeadlightsOn()` and
  `getHeadlightCanEmmitLight()` are both true, so a flat battery or broken bulbs mean
  no light, as for the headlights themselves. Leaving the vehicle, switching the
  headlights off or turning the option off removes it.
- **Where.** On the vehicle's tile. It moves when the tile changes, at most 20 times a
  second, because every move makes the game relight the surroundings. At speed the lit
  area follows in small steps, as a lightbar's glow does.
- **What.** One steady light (`life = -1`; any other value makes the game treat it as a
  fading flash), slightly warm. `area_light_radius` (3–20 tiles, default 8) and
  `area_light_brightness` (0.1–1.0, default 0.6) can be tuned in the settings file only.
- **Saved?** No. The light is an in-memory entry in the cell's lamppost list, not part
  of any saved object, and it ends with the world.
- **Removal.** On the game thread the light is withdrawn through `removeLamppost`.
  Turning off, disconnecting and faults happen on other threads, which must not call
  into the game, so they only mark the module's own light as ended (`life = 0`); the
  game drops it on its next lighting pass.
- **Isolation.** The light's game accessors are checked separately from the driving
  ones. If a game update changes them, or placing a light throws, only the light is
  unavailable for that activation (`area_light=unavailable` or `failed:…` in
  diagnostics). Acceleration, reversing and steering carry on.

Observation-only mode (`probe_only`) places no light.

## Settings

Defaults and allowed ranges are in [vehicle-drivetrain.toml](../config/game-extensions/vehicle-drivetrain.toml).
Your overrides go in `%LOCALAPPDATA%/PzTools/extensions/vehicle-drivetrain.toml`. Both
the app and the extension check a fixed copy of the settings before applying it; the
code running in the game never reads the file.

The four switches in the app override the file's defaults, even before they are first
saved. The extension itself starts off; all four options start on. A saved preference
without the light's switch (written before the light existed) reads it as on, like any
other unwritten switch. An older saved preference `probeOnly=true` is read as every
option off, and the file is not rewritten just because it was read. Low-gear mode,
observation, diagnostics and numeric tuning are developer options in the file only.

What you saved and what the game is running are tracked separately (see
[settings revision](glossary.md#settings-revision)). The switches stay editable while
the game is not connected or a change is still waiting for a safe moment. Revisions,
hashes and the reasons for each transition go to the logs. If a change fails, only
that request is turned off, and a newer choice you made in the meantime is never
overwritten.

## Connection and lifecycle

[RuntimeExtensionCoordinator](../src/PzTools.State.Scheduler/RuntimeExtensionCoordinator.cs)
in the state scheduler owns the connection to the game: authentication, heartbeat,
delivering settings and reconnecting. It uses the same choice of game process as the
rest of the state scheduler; with no suitable game, or more than one, nothing is
started. Saving, the [WATCH](glossary.md#watch) stream and extension control are
separate; each continuous module has its own slot on the shared
[control lease](glossary.md#control-lease). See
[several modules on one connection](game-extensions.md#several-modules-on-one-connection).

The module ships as `pztools-vehicle-drivetrain.jar` with capability
`vehicle.drivetrain.v1`. The version numbers it depends on are listed in the
[compatibility table](save-bridge.md#compatibility-and-lifecycle). The optional save
extension is not distributed; a backup's game save always goes through
`GameWindow.save(true)`.

**Requests.** Each control request carries its own identity, the controller's epoch,
the game process and world, and the settings revision it expects. Retries are safe to
repeat, queues and caches are bounded, and a new controller cannot take over while the
current owner is alive. The lease lasts five seconds.

**Safe moment.** Turning the extension on or changing its settings waits for a safe
moment on the game thread: all vehicles stopped, accelerator released and cruise
control off. Turning off, disconnecting, a fault or an expired lease close the module
to new calls at once, without waiting for a game update.

**Disconnecting.** The session stops letting calls in immediately, but stays
responsible for the module until its calls in progress and its retirement have
finished. Late callbacks and repeated close requests do nothing. The game thread
checks the session without blocking, so commands and retirement never make the game
wait.

**Scope.** State belongs to one game process, world, module generation, vehicle and
driver, so a vehicle ID reused later cannot bring old state back. Leaving the game,
changing worlds, retirement and faults release everything. After a fault the game's
own control is used until you turn the option on again, change the settings, or a new
module version arrives.

## Replacement and failure handling

Replacing the module is described in general in [component updates](module-reload.md).
For this module:

- **Checks first.** The archive, its interface version, the settings and the bytecode
  are checked before a healthy generation is retired. If any check fails, the current
  generation stays installed and reports `update-rejected`; the app can then safely
  turn off the request that failed.
- **Failure while installing.** If installation itself fails, the game's own control
  may be left in place rather than the old generation restored.
- **Unclear retirement.** If retirement is uncertain or does not finish in time, the
  state becomes `RestartRequired`. Reconnecting or changing worlds does not clear it.
- **Order.** New calls are refused before the module waits for calls in progress.
  Cleanup never waits for a game update that is already paused, and never holds a lock
  a call in progress needs.
- **Other transformers.** Only this module's own transformer is removed.
  Retransformation never overwrites other agents' changes with bytes read again from
  disk. Before replacing, the checks tell the game's input apart from this module's
  own earlier output and look at later Java transformers in the same pass; installation
  checks again. These checks cannot stop transformers registered later, or changes made
  through native agents (JVMTI) or JNI. Repeated reload tests must tell the module's
  own earlier hooks apart from real outside conflicts.

## Verification and what is still open

**Automated.** Model outputs are finite and bounded; direction changes, varying time
steps, shift hysteresis and steering reversals are covered; the adapter's field and
native-argument results, equivalence on fallback, lifecycle drain, settings revisions
and repeated replacement are tested. Installed-JAR checks read your game JAR in a
separate Java process that does nothing else; game code is never copied into test
fixtures or distributed.

**Diagnostics** are opt-in: the latest sample plus one-second summaries.

- `requested_force` in observation mode is a one-step prediction from a reset state.
- `native_force`, `native_brake` and `native_steering` are the arguments just before
  the game's native call, not proof that the call succeeded.
- Callback timings leave out the game's own and native code, so they must not be shown
  as the total cost per frame.

**Still open in a real game:** what native force, radius and time values mean; road
and offroad behaviour; loaded and towing vehicles; reverse launch; steering feel;
fuel and noise; varying frame rates; and running together with saving, WATCH and
module updates. Any performance target needs a measurement of the unmodified game
first. Synthetic tests show neither higher FPS nor that every mod works with it.

## References

The design drew on [Better Car Physics](https://steamcommunity.com/sharedfiles/filedetails/?id=2909035179),
[BVD at d96dea6](https://github.com/grphx/better-vehicle-dynamics/blob/d96dea603c1c1665c486e3a0ed5bad16e2d23366/mods/better-vehicle-dynamics-42/patches/zombie/core/physics/CarController.java.patch)
and [TVP at a3c28b2](https://github.com/pocket120/True_Vehicle_Physics_B42_Project_Zomboid/blob/a3c28b24c90beaf74cf3e589027e19c7f56c36ae/TrueVehiclePhysics/Contents/mods/truevehiclephysics/42/media/lua/shared/TrueVehiclePhysicsTransmission.lua).
