# Testing the vehicle extension

[Documentation index](../README.md)

A manual procedure for trying **Vehicle driving improvements** in a real game: compare each
option with the game's own driving, check that settings reach the game, and back out
safely. How the extension works is in the [design](../design/vehicle-drivetrain.md); what a
player sees is in [better vehicle controls](../guides/vehicle-controls.md).

## Before you start

1. Use a throwaway single-player world that already has a backup. Turning the extension
   off does not undo movement, collisions or fuel; the backup does.
2. Disable other mods that change vehicle physics or input.
3. Run a complete published folder (app, workers, bridge and extension), not a single
   replaced JAR. Close any other PZ Tools instance first, including one in the tray.
4. If the sidebar shows **PZ Tools was updated** with **Restart the game.**, an older
   bridge is still loaded in the game: restart the game fully once. Otherwise the game may
   be started before or after the app.
5. On the **Logs** page, show **Information or higher**. Normal state changes of the
   extension are recorded at that level.

## What the extension applies to

| Part | Applies to | Uses the game's own code for |
| --- | --- | --- |
| Acceleration, shifting, reverse | Four-wheel vehicles with a running engine, engine type `generic`, `van`, `jeep` or `firebird`, 3–5 gears | Other engine types or gear counts, stopped engines, towed or burnt vehicles, towing a burnt vehicle |
| Keyboard steering | Keyboard-controlled vehicles, also with the engine off or an unsupported engine type | Gamepad steering, towed and burnt vehicles |

The catalogue declares game version 42. The code checks were reviewed against 42.20.4; a
later 42.x patch can still fail them, and then the extension does not start.

## Turning it on

Open **Game extensions**. The switch for **Vehicle driving improvements** is in the card
header; expand the card for the four options:

- **Natural acceleration and shifting**
- **Smooth reversing**
- **Precise keyboard steering**
- **Light around the vehicle**

The extension starts off and all four options start on. A change applies at a
[safe moment](../design/vehicle-drivetrain.md#safe-point-for-applying-changes): the game
running (not paused), and every vehicle you sit in stopped, with the accelerator released
and cruise control off. Until then the card says **To apply, resume the game, stop the vehicle,
release the accelerator, and turn off cruise control.**

## Comparing with the game

Test one option at a time. Compare off → on → off with the same vehicle, cargo, tyres,
engine condition, road and character traits.

| Option | What to do | What to look for |
| --- | --- | --- |
| **Precise keyboard steering** | Tap and hold a direction, release, hold the other direction. Reverse again before the wheels reach the centre. Repeat equal short taps. | Equal taps turn the wheels by equal amounts. On release the wheels start back without an extra step outwards. Gamepad steering, aiming and typing behave as before. |
| **Smooth reversing** | Pull away in reverse and hold it; brake to a stop, then reverse | A ramp of about 0.8 seconds, no further force cut after it, top speed at the vehicle's own reverse limit (its script value ÷ 1.5) |
| **Natural acceleration and shifting** | Pull away, shift from first to second, accelerate out of a corner | No gear hunting, no early loss of force at low speed, no long gap in force after pressing the accelerator again |
| **Light around the vehicle** | At night, headlights on and off | Ground lit around the vehicle only while the headlights are on and working |

The steering curve, its speed scaling and the return to centre are the game's own. Only the
timing of key presses changes, so the vehicle going straight at once after release is not
the pass condition.

For first feedback, a line per finding is enough: vehicle, option, what happened.

## Broader driving checks

Keep the conditions fixed and compare each character trait against the game with the same
trait.

| Area | Check | Stop and report if |
| --- | --- | --- |
| Reverse and direction changes | Distance after 0.2, 0.5 and 1 second; the launch ramp; the speed limit; braking before reversing | The vehicle lurches, pushes the wrong way, or brake and reverse lights disagree |
| Steering | Low and high speed, reverse, release, repeated opposite input; compare with a gamepad | The wheels hesitate at the centre, the gamepad behaves differently, the wheels and the actual turn disagree |
| Transmission | 3-, 4- and 5-gear vehicles, re-acceleration, RPM gauge and engine sound | Shifts up to top gear while standing, hunts between gears, RPM looks wrong |
| Offroad | Slow from a high gear with the accelerator held; downshift and climb out | Unlimited pulling power, or much worse escape than the game |
| Cargo and towing | Empty and loaded, normal towing, towing a burnt vehicle (game fallback) | Power rises with cargo, or a trailer pushes itself |
| Input safety | Coasting, brake, parking brake, engine start, cruise control, drunk driving, unloaded chunks | Lost braking, or a jolt when releasing the parking brake |
| Side effects | Fuel use, engine noise, zombies drawn by it, getting out and back in | Clear changes, or state kept for the wrong driver or vehicle |
| Frame rate | 30, 60 and uncapped FPS; pause and resume; a hitch | Catch-up acceleration after a pause or hitch |
| Light around the vehicle | Engine off with headlights on, flat battery, broken bulbs, getting out, driving fast, a garage or tunnel, the option off while lit, the extension off while lit, leaving to the menu and reloading | Light left behind, light through the walls of a closed room, flicker while driving, a light after reloading the save |

## Settings and lifecycle

- **Switches.** They show the saved choice, not what the game is running, and stay usable
  with no game, while paused and while driving. The last saved choice applies at the next
  safe moment. Expanding the card, scrolling and status refreshes must not move focus or
  rebuild the page.
- **Ignore supported version range** skips only the game-version check. It does not turn
  the extension on, and the code checks still run.
- **Failures.** A failure turns off the request that failed, never a newer choice saved in
  the meantime, and is not retried without a new change. **The extension could not be
  applied. Check the logs for details.** means the **Logs** page has the reason. After
  `RestartRequired` nothing loads again until the game restarts.
- **Backups.** Run manual and automatic backups while the extension is active. Each backup
  still saves through the game's own `GameWindow.save(true)`. The in-game "saved" note and
  the app's "backup complete" are separate, and no backup is duplicated.
- **Restarting the app.** Exit and start the app three times in one game session, then leave
  and load worlds. The extension must come back each time without old state.
- **Turning off.** Turn the extension off, and exit the app, with the game paused. Stop the
  vehicle before turning it off during a test: control returns to the game at once, and
  the game's own force can differ.
- **Disconnects.** When the control connection ends (the app closes or is killed), the
  extension stops at once. A connection that stays open but goes silent ends with the
  five-second control lease.

If something behaves badly, turn the extension off. If the card or logs show
`RestartRequired` or the state is unclear, end the test and close the game. Restore the
backup to get back to the earlier state.

## Developer settings

### Tuning file

Defaults and allowed ranges are in
[`vehicle-drivetrain.toml`](../../config/game-extensions/vehicle-drivetrain.toml). To
override them, create `%LOCALAPPDATA%\PzTools\extensions\vehicle-drivetrain.toml` with only
the keys you change. A value out of range, an unknown key or a duplicate key rejects the
whole file, and the request is turned off.

| Key | Use |
| --- | --- |
| `diagnostics_enabled = true` | Adds the latest driving sample and one-second totals to the extension's log entries, which are written only when its state changes |
| `probe_only = true` | Leaves the game in control and only predicts one step from a reset state. Not for driving comparisons; turn it off again. |
| `steering_precise_input = false` | Uses the game's once-per-frame key reading, to compare against |
| `forward_torque_boost_fraction` | 0 to 0.10 (default 0.10). 0 removes only the RPM-dependent forward boost, leaving shifting and pedal response. |
| `low_mode` | Developer low-gear mode |

The app's four switches override `torque_enabled`, `reverse_enabled`, `steering_enabled`
and `area_light_enabled` in the file. The file is read only when a new settings revision
is sent: after editing it, turn any switch off and on again, load another world, or restart
PZ Tools (**Apply settings and restart**).

An override file from an earlier build may still hold old reverse values (`22`, `0.85`,
`0.75`) that hide today's defaults: `reverse_max_speed_kph = 0` (the vehicle's own limit),
`reverse_force_ratio = 1`, `reverse_governor_start_fraction = 1`. An explicit reverse
limit must be 4–35 km/h. Old steering rate keys are ignored.

### Reading the diagnostics

The sample is attached to the `extension.runtime.changed` entry on the **Logs** page,
which is written when the extension's state changes, not continuously: steady driving adds no
entry. To take a sample at a moment you choose, change one of the vehicle switches there and then:
the request it starts is a state change, and its entry carries the sample of that moment.

- `native_force`, `native_brake`, `native_steering` are the arguments just before the
  game's native call, not proof that the call succeeded.
- `callback_mean_us` and `callback_max_us` leave out the game's native code; they are not
  the cost per frame.
- `steering_precise`, `steering_timing` (`direct`, `confirmed` or `frame`) and
  `steering_keys` show whether keys are being timed and, if not, why.
- A large `sample_age_ms` means the sample is old.

### Connection timing

In `%LOCALAPPDATA%\PzTools\config\state-scheduler\default.toml`, under `[extensions]`:

| Key | Range | Default | Controls |
| --- | --- | --- | --- |
| `reconcile_interval_ms` | 250–1000 | 1000 | How often preferences are checked and the connection renewed |
| `connect_timeout_seconds` | 5–60 | 20 | Time allowed to open the connection |

Apply them with **Apply settings and restart** (see
[advanced settings](../reference/advanced-settings.md#applying-changes)). Neither changes the
five-second lease or the command time limits (15 seconds for `APPLY` and `OFF`, 3 seconds
for the others).

## Automated checks before a test session

From the repository root, with a JDK 25 in `$jdk` and the game's `projectzomboid.jar` in
`$gameJar`:

```powershell
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
./scripts/test-game-bridge.ps1 -JdkPath $jdk -Configuration Release -ReuseBuild -PrepareOnly
./scripts/test-game-extensions.ps1 -JdkPath $jdk -Configuration Release -InstalledGameJar $gameJar
dotnet test tests/PzTools.Backup.Tests -c Release --no-build
./scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/vehicle-validation/app
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/vehicle-validation/app).Path
dotnet test tests/PzTools.Backup.Tests -c Release --no-build --filter FullyQualifiedName~PublishedDistributionTests
```

`test-game-bridge.ps1 -PrepareOnly` runs the Java bridge and extension tests and leaves the
test variables set in the session, so the next `dotnet test` includes the bridge tests.
`-InstalledGameJar` checks the bytecode of your installed game in a separate Java process;
it does not start or attach to the game. Its log goes to
`artifacts/game-extension-tests/installed-vehicle-verification.log`
(`-InstalledVerificationLog` changes it, outside the game folder). The publish folder must
be new or empty. Record the commit, the commands, the results and the published folder
with its `pztools-files.txt` next to the test notes.

To check another mod's class replacements without installing it, add
`-GameOverrides path\to\classes.zip` to the `test-game-extensions.ps1` line. The classes must
sit at their package paths from the archive's root. The archive's classes take precedence
over the installed JAR, and the check fails if none of them is used. A pass means the
extension's access and patch points still match; if the mod changes input or physics
stepping, still test steering, braking and timing in the game.

These checks do not replace driving in the game.
