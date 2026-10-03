# Testing the vehicle extension

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

This is a hands-on procedure for trying the [game extensions](game-extensions.md) in a
real game: **Vehicle driving improvements** 0.2.0. It is for testers who want to
compare it with the original game, check that settings apply as
expected, and back out safely. Vehicle driving improvements is experimental and off by
default.

This page is a test procedure, not a finished driving report. The
[design document](vehicle-drivetrain-design.md) describes the supported build, the
driving model and the calibration work still open.

## Before you start

1. Use a disposable single-player world that already has a backup.
2. Start with a standard vehicle, and disable other Java vehicle-physics patches.
3. Check the app's save and backup paths. Settings and logs are shared under
   `%LOCALAPPDATA%/PzTools`.
4. Run a complete Windows x64 distribution containing the app, workers, bridge,
   extension runtime and vehicle module. Do not update a test installation by copying
   only one JAR.
5. Close any earlier app, including its tray instance, and make sure a developer
   `PZTOOLS_TOOLS_DIR` override does not point somewhere else.
6. If the game has already loaded an older, incompatible
   [bootstrap](glossary.md#bootstrap), restart the game fully once. The
   [compatibility table](game-bridge.md#compatibility-and-lifecycle) lists which
   bootstrap versions need this. Starting the game before the app is fine when no older
   agent is resident, and while the bootstrap stays compatible, restarting the app does
   not require restarting the game each time.

## Which vehicles and builds are covered

The [catalogue](../config/game-extensions/catalog.tsv) declares major version 42. The
mandatory bytecode and structural checks still target the inspected 42.20 build;
declaring the range does not guarantee every 42.x patch.

| Part | Applies to | Uses the original game instead |
| --- | --- | --- |
| Propulsion (acceleration, shifting, reverse) | Four-wheel vehicles with engine type `generic`, `van`, `jeep` or `firebird` and 3–5 gears | Unknown profiles, stopped engines, towed or burnt vehicles, and towing a burnt vehicle |
| Keyboard steering | Checked on its own, so it can apply with the engine off or with an unsupported propulsion profile | Gamepad steering, towed and burnt vehicles |

## First comparison

Open **Game extensions → Vehicle driving improvements**. The switch for the whole
extension is on the right of the card header; expand the card to see:

- **Natural acceleration and shifting**
- **Smooth reversing**
- **Precise keyboard steering**
- **Light around the vehicle**

The extension itself starts off; all four options start on, so turning the extension on
enables everything. With everything off you have the original game. Preferences saved
by older observation-only versions are read as everything off.

1. Turn on only **Precise keyboard steering**.
2. Resume the game, stop on level ground, and release acceleration and cruise control
   so the saved settings can apply (the [safe boundary](glossary.md#safe-boundary)).
3. Compare **off → on → off** with the same vehicle, load, tyres, engine condition,
   road and character traits.
4. Repeat for the other options.

| Feature | What to compare |
| --- | --- |
| Steering | Tap and hold a direction, release it, then hold the opposite direction. Check return to centre and repeated reversals, including a second reversal before reaching centre. Watch both the wheels and the actual turn. |
| Reverse | Compare launch and sustained reverse. Check the default 0.8-second launch ramp and the vehicle-specific speed limit. There should be no 22 km/h cap (as in earlier versions) and no further force reduction after the ramp. |
| Acceleration/shifting | Compare launch, first-to-second gear, and acceleration after a corner. Watch for gear hunting, early loss of low-speed force, or a long force gap after reapplying input. |

For initial feedback, report `vehicle / enabled option / observed behavior`. Developer
diagnostics are optional.

### Checking the key-release fix

Tap and hold each direction, then release it or alternate directions quickly. The
front wheels should start returning without an extra outward steering step from the
old input.

- Return-rate settings and the game's own body rotation and sliding are unchanged, so
  the vehicle going straight at once is not the pass condition.
- Gamepad behaviour and the game's aiming and text-input restrictions must stay
  intact.
- Steering keeps the game's response curve and speed scaling. What to judge is
  repeatability: equal short taps should turn the wheels by equal amounts.

To compare against the game's own per-frame key timing, set
`steering_precise_input = false` in the override file. With diagnostics on,
`steering_precise` and `steering_keys` show whether keys are being timed and, if not,
why.

## Check the settings and how they apply

**Switches.** The switches show the saved preferences. While changes are waiting to
apply, the card should explain why and keep the controls available, without a progress
indicator that never ends. You should be able to change settings offline, while paused
or while driving. The last saved choice should apply after you resume, stop, release
acceleration and turn off cruise control.

**Page state.** Expand and collapse the card, scroll, and focus a control. Status
refreshes and quick switch changes must keep all of that without rebuilding the page.
The main switch stays visible when the card is collapsed, and all expanded rows can be
reached with the mouse wheel, the scrollbar and Tab.

**Ignore supported version range** is a separate inline row. It skips the declared
version range, keeps the mandatory code checks, and does not turn the extension on by
itself. Low mode, observation and diagnostics are developer-only TOML options.

**Failures.** A confirmed failure may turn off the matching request. It must not
overwrite a newer saved choice, and a failed request must not be retried again and
again without a new change. [`RestartRequired`](glossary.md#restart-required) stays
locked until the game restarts. Application revisions, module versions and hashes, and
the reasons for each transition are in the logs; choose log level Information or above
to see normal transitions.

**Backups.** The game-save and countdown settings for backups are separate. When
enabled, a backup uses `GameWindow.save(true)`; the vehicle settings do not choose a
different save provider. The in-game "save completed" notice and the app's "backup
completed" state must stay distinct.

## Broader driving checks

Keep the comparison conditions fixed, and test each character trait against the
original game with the same trait.

| Area | Check | Stop for |
| --- | --- | --- |
| Reverse/direction changes | Distance after 0.2, 0.5, and 1 second; launch ramp; vehicle limit; braking before reversing | Sudden launch, opposite-direction propulsion, inconsistent brake/reverse signals |
| Steering | Low/high speed, reverse, release, repeated opposite input, gamepad comparison | Delayed restart at center, changed gamepad behavior, visual/physical disagreement |
| Transmission | 3/4/5 gears, reacceleration, RPM/display/sound | Stationary upshifts to top gear, gear hunting, abnormal RPM |
| Offroad | Slow from a high gear with the pedal held; compare downshift and escape ability | Unlimited boost or substantially worse escape ability |
| Load/towing | Empty/loaded car, normal towing, unsupported towing fallback | Power rising with added cargo or self-propelled trailers |
| Input safety | Coast, normal/parking brake, starting, cruise, intoxication delay, unloaded chunks | Lost safety braking or a delayed parking-release ×8 force spike |
| Side effects | Fuel, sound, zombie attraction, exit/re-entry | Excessive changes or retained driver/vehicle state |
| Timing | 30/60/high FPS, pause/resume, delayed frames | Catch-up acceleration or sharply increased callback cost |
| Light around the vehicle | At night: headlights on/off, engine off with headlights on, flat battery, broken bulbs, getting out and back in, driving fast, entering a garage or tunnel, option off while lit, extension off while lit, leaving to the menu and reloading | Light left behind after any of these, light inside closed rooms through walls, visible flicker or stutter while driving, a light present after reloading the save |

## Lifecycle checks

1. While the extension is confirmed active, run manual and automatic backups together
   with the [WATCH](glossary.md#watch) stream, and check that no backup is duplicated.
2. Exit and restart the app three times within one game session (one game JVM), then
   leave and open worlds. Old model state and
   [generations](glossary.md#generation-module) must not leak into later sessions.
3. Turn the extension off, and exit the app, while the game is paused.
4. Stop the vehicle before turning the extension off during a test. Turning it off
   explicitly can release control while moving, but going back to the original game
   need not keep the same force.

What to expect:

- A disconnect stops new callbacks at once, without waiting for a game tick. If the
  app is terminated abruptly, it can take up to the five-second
  [control lease](glossary.md#control-lease) to notice.
- If an archive or configuration is rejected before installing, that alone does not
  replace a healthy module generation already running in the game. The app can turn
  off the matching rejected request.
- A failure while installing, or a conflict with another transformer, may instead
  return to the game's original control. If retirement or draining is uncertain, the
  game has to be restarted.

## If something goes wrong

- If behaviour is abnormal, stop and turn the extension off.
- If the state is unclear or `RestartRequired` appears, end the test and close the game
  fully.
- Turning the extension off does not rewind movement, collisions or fuel. Use your
  backup to go back to the earlier test state.

## Developer tuning and diagnostics

### Settings file

Defaults and ranges are in
[vehicle-drivetrain.toml](../config/game-extensions/vehicle-drivetrain.toml). Overrides
go in `%LOCALAPPDATA%/PzTools/extensions/vehicle-drivetrain.toml`, with only the flat
keys you need. Both .NET and Java validate keys, ranges, duplicates and cross-field
constraints.

The four switches in the app take precedence over the file's feature defaults, even
before they are first saved to JSON. `low_mode`, `probe_only`, `diagnostics_enabled`
and the numeric values can only be set in the file. After editing it, stop and switch
the extension off and on to apply a new revision.

`forward_torque_boost_fraction` controls only the RPM-dependent forward boost, from 0
to 0.10 (default 0.10). Set it to 0 to compare the extension's shifting and pedal
response without this extra boost. Unlike `force_scale`, it does not scale reverse
output or the whole forward force envelope.

**Older override files.** Existing overrides are not deleted automatically. In
particular, the old reverse values `22`, `0.85` and `0.75` can hide the current
defaults, which are `reverse_max_speed_kph=0`, `reverse_force_ratio=1` and
`reverse_governor_start_fraction=1`. An explicit reverse limit must be 4–35 km/h. Older
steering rate settings are ignored.

### Connection timing

Connection timing is set in the state scheduler's `default.toml`, under `[extensions]`:

| Key | Range | Default | Controls |
| --- | --- | --- | --- |
| `reconcile_interval_ms` | 250–1000 ms | 1000 | Preference checks and heartbeats |
| `connect_timeout_seconds` | 5–60 seconds | 20 | Time allowed for preparing the first connection |

Restart the app after changing these. Neither changes the fixed five-second control
lease or the three-second command limit.

### Diagnostics

- `probe_only=true` keeps the original control and reports a one-step prediction from a
  reset state, not continuous driving performance. Turn it off before ordinary driving
  comparisons.
- Diagnostics keep the latest sample and one-second aggregates.
- `native_force/brake/steering` are the arguments before the native call, not evidence
  that the native call succeeded.
- `callback_mean_us/max_us` leave out native execution and the cost of observation.
- An old `sample_age_ms` means the last sample is stale.

## Automated reproduction

Run from the repository root, with a Java 25 JDK in `$jdk` and your installation's
game JAR in `$gameJar`. Installed-JAR validation uses a separate JVM and does not attach
to a running game. Choose a fresh output directory when publishing.

```powershell
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
./scripts/test-game-bridge.ps1 -JdkPath $jdk -Configuration Release -ReuseBuild -PrepareOnly
./scripts/test-game-extensions.ps1 -JdkPath $jdk -Configuration Release -InstalledGameJar $gameJar
$env:PZTOOLS_LIVE_PROBE_PID = $null
$env:PZTOOLS_LIVE_PROBE_SAVE = $null
$env:PZTOOLS_REAL_SAVES_ROOT = $null
dotnet test tests/PzTools.Backup.Tests -c Release --no-build --logger 'trx;LogFileName=vehicle-regression.trx'
./scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/vehicle-validation/app
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/vehicle-validation/app).Path
dotnet test tests/PzTools.Backup.Tests -c Release --no-build --filter FullyQualifiedName~PublishedDistributionTests
```

Record the commit, commands, results and distribution hashes next to the candidate.
Automated checks do not replace the driving and lifecycle checks above.

### Checking another mod's class replacements

To check a third-party class replacement archive without installing it, add
`-GameOverrides path/to/classes.zip` to `test-game-extensions.ps1`, together with
`-InstalledGameJar`.

- Each class must be at its declared package path in the archive root; an extra
  release folder is rejected.
- The verifier checks resource and class-loading sources, and rejects the archive when
  none of its classes are used.
- It reports both the number of validated paths and the actual override definitions.
  It does not claim to exercise every class in the archive.
- Archive classes come before the installed JAR, while normal parent-loader precedence
  is kept and checked for shadowing.
- It reads class metadata and exercises the transformations in a separate JVM; it does
  not start or attach to the game.

A pass confirms access and patch contracts only. When another mod changes input
sampling or physics stepping, test steering, braking and timing in the game
separately.
