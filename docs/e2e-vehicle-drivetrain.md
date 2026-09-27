# Testing Vehicle Driving Improvements

[Documentation index](README.md) · [User guide](../README.md)

Vehicle Driving Improvements 0.2.0 is experimental and off by default. This is a test procedure, not a completed driving report. The [design document](vehicle-drivetrain-design.md) describes the supported build, model, and remaining calibration work.

## Prepare

Use a disposable single-player world with an existing backup. Start with a standard vehicle and disable other Java vehicle-physics patches. Check the app's save and backup paths before testing; settings and logs are shared under `%LOCALAPPDATA%/PzTools`.

Run a complete Windows x64 distribution containing the app, workers, bridge, extension runtime, and vehicle module. Close any earlier app, including its tray instance, and ensure a developer `PZTOOLS_TOOLS_DIR` override does not point elsewhere. Do not update a test installation by copying only one JAR.

A game that already loaded bootstrap API9 or earlier needs one full restart. Starting the game before the app is supported when no older agent is resident; compatible API10 app restarts do not require restarting the game each time.

The catalog declares major version 42. Mandatory bytecode and structural checks still target the inspected 42.20 build; the declaration does not guarantee every 42.x patch. Propulsion candidates are four-wheel vehicles with `generic`, `van`, `jeep`, or `firebird` engine types and 3–5 gears. Unknown profiles, stopped engines, towed/burnt vehicles, and burnt-vehicle towing use original propulsion. Keyboard steering is checked independently and can apply with the engine off or an unsupported propulsion profile. Gamepad, towed, and burnt-vehicle steering remains original.

## First comparison

Open **Game extensions → Vehicle Driving Improvements**. The extension-wide switch is on the right of the header; expand it to see:

- **Natural acceleration and shifting**
- **Smooth reversing**
- **Fine steering control**

New feature preferences start on, but the extension itself starts off. All three off means original driving. Older observation-only preferences are read as all three off.

Begin with only Fine steering control enabled. Resume the game, stop on level ground, and release acceleration and cruise so the saved settings can apply. Compare **off → on → off** with the same vehicle, load, tires, engine condition, road, and character traits.

| Feature | What to compare |
| --- | --- |
| Steering | Tap and hold a direction, release it, then hold the opposite direction. Check return to center and repeated reversals, including a second reversal before reaching center. Watch both the wheels and actual turn. |
| Reverse | Compare launch and sustained reverse. The default 0.8-second launch ramp remains, but there should be no unnecessary universal 22 km/h cap or extra settled-force reduction. |
| Acceleration/shifting | Compare launch, first-to-second gear, and acceleration after a corner. Watch for gear hunting, early loss of low-speed force, or a long force gap after reapplying input. |

A useful first report is simply `vehicle / enabled option / improvement or problem`. Developer diagnostics are not required for initial feedback.

For the release-input fix, tap and hold each direction, then release it or alternate directions quickly. The front wheels should start returning without an extra outward steering step from the old input. Return-rate settings and native body rotation/sliding are unchanged: immediate straight-line travel is not the acceptance condition. Check that gamepad behavior and the game's aiming/text-input restrictions remain intact.

## Check settings and application

The switches display saved intent. Pending application has an explanation; it must not lock all options or spin indefinitely. You should be able to edit settings offline, paused, or while driving, and the last saved request should apply after resuming, stopping, and releasing acceleration/cruise.

Expand/collapse the card, scroll, and focus a control. Status refresh and rapid switch changes must preserve those states without rebuilding the page. The main switch stays visible when collapsed; all expanded rows remain reachable by wheel, scrollbar, and Tab.

Force-enable is a separate inline row. It bypasses the declared version range, preserves mandatory code checks, and does not enable the extension by itself. Low mode, observation, and diagnostics are not normal UI options.

Confirmed failures may turn off the matching request. They must not overwrite a newer saved choice or repeatedly retry a failed request without a new change. `RestartRequired` remains locked until the game restarts. Application revisions, module versions/hashes, and transition reasons are in the logs; choose Information or above to inspect normal transitions.

Backup's game-save and countdown preferences are separate. When enabled, backup uses `GameWindow.save(true)`; vehicle settings do not select a different save provider. The in-game save-completed notice and the app's backup-completed state must remain distinct.

## Broader driving checks

Keep the comparison conditions fixed and test each trait against vanilla with the same trait.

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

## Lifecycle and rollback

While the extension is confirmed active, exercise manual/automatic backup and WATCH together, checking that backup is not duplicated. Repeat app exit/restart three times in one game JVM, then leave/open worlds. Old model state and generations must not leak into later sessions.

Test off and app exit while paused. Disconnect closes new callback admission without a game tick; abrupt termination can take up to the five-second lease to be detected. Explicit off can release control while moving, but stop before changing it during a test: returning to vanilla need not preserve the same force.

Archive/configuration preflight rejection does not itself replace a healthy JVM generation. The app can turn off the matching rejected request. Installation-stage failure or transformer conflicts may instead return to original control; uncertain retirement/drain requires a game restart.

If behavior is abnormal, stop and turn the extension off. If the state is unclear or `RestartRequired` appears, end the test and fully close the game. Disabling does not rewind movement, collisions, or fuel; use your backup to restore the earlier test state.

## Developer tuning and diagnostics

Defaults and ranges are in [vehicle-drivetrain.toml](../config/game-extensions/vehicle-drivetrain.toml). Overrides belong in `%LOCALAPPDATA%/PzTools/extensions/vehicle-drivetrain.toml`; only needed flat keys are required. Both .NET and Java validate keys, ranges, duplicates, and cross-field constraints.

The three UI preferences take precedence over TOML feature defaults, even before the first JSON save. `low_mode`, `probe_only`, `diagnostics_enabled`, and numeric values remain TOML-only. After editing, stop and toggle off/on to apply a new revision.

Existing overrides are not deleted automatically. In particular, old reverse values `22`, `0.85`, and `0.75`, or older steering return/countersteer rates, can mask current defaults. Current defaults are `reverse_max_speed_kph=0`, `reverse_force_ratio=1`, `reverse_governor_start_fraction=1`, and steering return/countersteer rates of 8. Explicit reverse limits accept 4–35 km/h.

`probe_only=true` keeps original control and reports a reset one-step prediction, not continuous driving performance. Disable it before ordinary driving comparisons. Diagnostics retain a latest sample and one-second aggregates. `native_force/brake/steering` are pre-call arguments, not evidence of native success; `callback_mean_us/max_us` exclude native execution and observation cost. An old `sample_age_ms` means the last sample is stale.

## Automated reproduction

Run from the repository root with a Java 25 JDK in `$jdk` and your installation JAR in `$gameJar`. Installed-JAR validation uses a separate JVM and does not attach to a running game. Choose a fresh output directory when publishing.

```powershell
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
./scripts/test-save-bridge.ps1 -JdkPath $jdk -Configuration Release -ReuseBuild -PrepareOnly
./scripts/test-game-extensions.ps1 -JdkPath $jdk -Configuration Release -InstalledGameJar $gameJar
$env:PZTOOLS_LIVE_PROBE_PID = $null
$env:PZTOOLS_LIVE_PROBE_SAVE = $null
$env:PZTOOLS_REAL_SAVES_ROOT = $null
dotnet test tests/PzTools.Backup.Tests -c Release --no-build --logger 'trx;LogFileName=vehicle-regression.trx'
./scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/vehicle-validation/app
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/vehicle-validation/app).Path
dotnet test tests/PzTools.Backup.Tests -c Release --no-build --filter FullyQualifiedName~PublishedDistributionTests
```

Record the commit, commands, results, and distribution hashes beside the candidate. Automated checks do not replace the driving and lifecycle checks above.
