# Development and validation

[Documentation index](../README.md)

Building, testing, publishing and releasing PZ Tools from source on a Windows x64 machine.
To install a release instead, see [getting started](../guides/getting-started.md).

## Prerequisites

| Tool | Why |
| --- | --- |
| The .NET SDK named in [`global.json`](../../global.json) (10.0.401, later patches accepted) | Every C# project |
| A Windows x64 JDK 25 | Compiles the Java bridge and extension, and builds the reduced Java runtime the app uses to attach. The game's own trimmed runtime cannot be used. |
| Visual Studio or Visual Studio Build Tools with the x64 C++ tools (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`) | Compiles the native attach bootstrap ([`build-game-bridge-native.ps1`](../../scripts/build-game-bridge-native.ps1) finds them with `vswhere`) |
| PowerShell 7.2 or later | The scripts under `scripts/` |
| Python 3.10 or later | The documentation, localization and CI-plan checks (standard library only) |

The WinUI app builds from the Windows App SDK NuGet packages that the project restores. To
edit and debug it in Visual Studio, also install the WinUI application development
workload.

The build looks for the JDK in this order: `-p:JdkPath=...`, then `JAVA_HOME`, then a single
`artifacts/toolchains/jdk-25*` folder. With none of them it stops with
"A Java 25 JDK is required". See [building the bridge](../design/game-bridge.md#building-and-publishing)
for where the bridge output goes.

## Repository layout

| Folder | Contents |
| --- | --- |
| `src/` | The app (`PzTools.App`, `PzTools.App.Core`), the schedulers, runners and workers (`*.Scheduler`, `*.Runner`, `*.Cli`), the Java bridge (`PzTools.GameBridge.Agent`, `PzTools.GameBridge.Native`) and the extensions (`PzTools.GameExtensions*`) |
| `tests/` | `PzTools.Backup.Tests` (the xUnit suite), the five WinUI smoke programs, and Java fixtures for the bridge and extension tests |
| `config/defaults/` | Each component's `default.toml`, copied into the app folder |
| `config/game-extensions/` | The extension catalogue and the vehicle extension's tuning defaults |
| `build/` | MSBuild files that build the Java payload and stage the workers next to the app |
| `scripts/` | Build, publish, release, test and check scripts |

How the processes fit together is in the [overview](../design/overview.md#the-pieces) and
[process architecture](../design/process-architecture.md).

## Build

Run from the repository root:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
```

Warnings are errors ([`Directory.Build.props`](../../Directory.Build.props)). The worker
projects build the Java and native bridge as part of the normal build, into
`artifacts/game-bridge/<Configuration>`. Do not copy bridge or worker binaries from an older
build into a new one.

The app lands in `src/PzTools.App/bin/x64/<Configuration>/net10.0-windows10.0.19041.0/win-x64/`.
[`AppWorkers.targets`](../../build/AppWorkers.targets) copies the workers and
`config/defaults` into its `workers` subfolder, also on F5 and Ctrl+F5 in Visual Studio.

### Running a development build

- A development build uses the same data folder as an installed app,
  `%LOCALAPPDATA%\PzTools`: the same settings, logs and backup folder. Point **Settings → Backup folder** at a
  test folder before you try anything destructive.
- Only one app runs per data folder. Starting a second one brings the running one
  (possibly hidden in the tray) to the front and exits. Close the installed app first.
- In a Debug build only, `PZTOOLS_TOOLS_DIR` names a different worker folder. A Release
  build always uses the workers in its own folder: it runs as administrator, and any
  program could set the variable.

### Previewing the sidebar's cards

Some cards need a state that is hard to bring about: a component blocked by Windows
Security, a lost or outdated game connection, a saves list that keeps failing to load, a
new release, the result cards. In a development build, **Settings → Advanced → Card preview
(developer build)** shows any of them; **Clear all** puts back the real state. For a
scripted run, set `PZTOOLS_PREVIEW_CARDS` to a comma-separated list of keys (or `all`)
before starting the app. The keys are in
[`MainWindowShell.CardPreview.cs`](../../src/PzTools.App/MainWindowShell.CardPreview.cs).

The preview goes through the same code as the real state, so it shows what users see, but
not whether the state is detected. Previewed warnings and errors write nothing to the log.
A published app has none of this: [`publish-app.ps1`](../../scripts/publish-app.ps1) passes
`PzToolsDistribution=true`, which drops the `PZTOOLS_DEV_TOOLS` symbol, and
`PublishedDistributionTests` checks that.

## Unit tests

```powershell
dotnet test tests/PzTools.Backup.Tests -c Release
```

The test project does not build the Java payload, so it needs no JDK. Tests that need
something outside the repository skip themselves, with the reason, unless their variable
is set. A skipped test is not a passed test.

| Variable | Enables |
| --- | --- |
| `PZTOOLS_DISTRIBUTION_DIR` | `PublishedDistributionTests` against a fresh `publish-app.ps1` folder ([below](#test-a-published-folder)) |
| `PZTOOLS_TOOLS_DIR` | Tests that start the published workers as separate processes |
| `PZTOOLS_GAME_BRIDGE_DIR`, `PZTOOLS_BRIDGE_TEST_JAVA`, `PZTOOLS_BRIDGE_TEST_CLASSES`, `PZTOOLS_EXTENSION_FIXTURE_JAR`, `PZTOOLS_CONTINUOUS_FIXTURE_JAR` | Bridge and extension tests against the synthetic JVM. [`test-game-bridge.ps1`](#game-bridge-tests) sets them. |
| `PZTOOLS_REAL_SAVES_ROOT` | Read-only tests on a real `Zomboid\Saves` folder; with `PZTOOLS_TOOLS_DIR`, the process end-to-end tests |
| `PZTOOLS_RECOVERY_SAMPLES` | Character recovery on real saves (`;`-separated), edited only in temporary copies |
| `PZTOOLS_TEST_USN=1` | USN journal tests; needs an elevated shell |
| `PZTOOLS_TEST_FAT_DIR` | A full-scan backup from a FAT32 or exFAT folder |
| `PZTOOLS_LIVE_PROBE_PID`, `PZTOOLS_LIVE_PROBE_SAVE` | Connects to a running game and checks the save path without saving (with `PZTOOLS_GAME_BRIDGE_DIR`) |

Before pointing any of these at real data, read the test that uses it. Use a throwaway
world, never your live save.

### Running as administrator

The app's [manifest](../../src/PzTools.App/app.manifest) requires administrator rights, and
the workers it starts inherit them. `dotnet test` runs with your own rights. So anything
that depends on elevation is not proven by the test suite: USN journal access, the attach
helper handing files to the game's account, files the elevated workers create that the
player's account must read. Check such a change in the running app.
[`verify-a15.ps1`](../../scripts/verify-a15.ps1) does this in an administrator PowerShell:
it publishes the app, runs the suite with the real saves, published workers and USN tests
enabled, then starts the app for a manual checklist and checks that no PZ Tools process is
left after it closes.

## UI smoke tests

```powershell
pwsh scripts/test-ui-smoke.ps1
```

Five small WinUI programs open real pages and controls in a hidden window: tooltips, the
logs, Home, the game extension settings and every language's strings. They need no app
host, game or user data. `dotnet test` does not run them, so run this script after a UI
change. A building solution only shows that they compile. The renders are saved in
`artifacts/ui-smoke`.

`-Configuration` (`Debug` by default), `-Output` and `-TimeoutSeconds` (180 per program)
change where and how they run. The script fails if any program fails to build, times out,
exits with an error or does not write a result starting with `PASS`.

## Game bridge tests

```powershell
pwsh scripts/test-game-bridge.ps1 -JdkPath $jdk
```

[`test-game-bridge.ps1`](../../scripts/test-game-bridge.ps1) builds the bridge (Debug by
default), compiles the Java fixtures, runs the Java tests of the extension runtime,
control protocol and profiler, runs
[`test-game-extensions.ps1`](../../scripts/test-game-extensions.ps1), and finally runs
`GameSaveClientTests` against a synthetic JVM that imitates the game. None of it touches a
real game.

| Option | Effect |
| --- | --- |
| `-Configuration Release` | Uses `artifacts/game-bridge/Release` |
| `-ReuseBuild` | Uses the bridge from the last solution build instead of building it, and runs `dotnet test --no-build` |
| `-PrepareOnly` | Stops before `dotnet test`, leaving the test variables set in the session |
| `-GameBridgeOutput` | Another bridge folder, for example while a running game holds the DLL in the default one |
| `-CheckIncrementalBuild` | Rebuilds once more and fails if an unchanged build rewrote any output |

The variables persist only when the script runs in your own session (`./scripts/...`), not
under `pwsh scripts/...`. To run the whole suite with the bridge tests included:

```powershell
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
./scripts/test-game-bridge.ps1 -JdkPath $jdk -Configuration Release -ReuseBuild -PrepareOnly
dotnet test tests/PzTools.Backup.Tests -c Release --no-build
```

Checks in a real game are manual; for the vehicle extension see
[testing the vehicle extension](e2e-vehicle-drivetrain.md).

## Publish a runnable folder

```powershell
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

[`publish-app.ps1`](../../scripts/publish-app.ps1) first runs
[`publish-tools.ps1`](../../scripts/publish-tools.ps1), which publishes the twelve worker
executables and copies `config/defaults` to `defaults/`. Then it publishes the app into the
same folder (framework-dependent, `win-x64`, without symbols, `PzToolsDistribution=true`)
and writes `pztools-files.txt`: every published file with its size and SHA-256. The app
checks its folder against that list when it starts (see
[the app folder](../reference/files-and-folders.md#the-app-folder)).

| Option | Default |
| --- | --- |
| `-Output` | `artifacts/app`. Must be new or empty; the scripts never clear a folder. |
| `-Configuration` | `Release` |
| `-JdkPath` | `JAVA_HOME`, then `artifacts/toolchains` |
| `-GameBridgeOutput` | `artifacts/game-bridge/<Configuration>`. Use a fresh folder for a release, so the payload reuses nothing from development builds. |
| `-DotNetPath` | `C:\Program Files\dotnet\dotnet.exe`, else `dotnet` on `PATH` |

Distribute the whole folder. It holds the workers, defaults, Windows App SDK components
and the reduced Java runtime; `PzTools.App.exe` alone does not run. End users need the
[.NET 10 runtime for x64](https://dotnet.microsoft.com/en-us/download/dotnet/10.0).
Game JARs are never part of it.

Read the [repository format](../design/repository-format.md) before opening existing
backups with a development build. Repository schemas are not migrated automatically. If a
schema is incompatible, keep the data you need and choose a new, empty backup folder.

### Test a published folder

A normal test run does not show that the published workers are present or come from the
same build as the app. To check a fresh publication:

```powershell
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/app-local).Path
$env:PZTOOLS_TOOLS_DIR = $env:PZTOOLS_DISTRIBUTION_DIR
try {
    dotnet test tests/PzTools.Backup.Tests -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Distribution tests failed.' }
}
finally {
    Remove-Item Env:PZTOOLS_DISTRIBUTION_DIR, Env:PZTOOLS_TOOLS_DIR -ErrorAction SilentlyContinue
}
```

`--filter "FullyQualifiedName~PublishedDistributionTests|FullyQualifiedName~PublishedWorker"`
limits the run to the checks `build-release.ps1` uses.

## Releases

Releases are built by GitHub Actions from a tag, not on a developer's PC.

1. Raise `<Version>` in [`Directory.Build.props`](../../Directory.Build.props). Every
   assembly carries it and the Home page shows it.
2. Run the checks that need a real game locally; CI only has the synthetic JVM.
3. Commit, then push a tag named `v` and the version:

   ```powershell
   git tag v0.2.4
   git push origin v0.2.4
   ```

The tag runs the full CI ([below](#ci)), and then the `release` job:

1. fails unless the tag is `v<Version>`
2. downloads the release JDK (Temurin 25.0.4.1+1) from Adoptium and checks its SHA-256
3. runs `build-release.ps1`
4. attests the ZIP's build provenance, so anyone can check it with
   `gh attestation verify PzTools-v<version>-win-x64.zip --repo isxcsm/pz-tools`
5. uploads the ZIP and its `.sha256` to a **draft** release, which you publish by hand

If the tag's release is already published, the job fails instead of replacing its files.
A draft's files are replaced.

To try the job without a tag, run the workflow by hand (**Actions → CI → Run workflow**)
with **release_check**. It builds the package the same way and keeps it as an artifact for
seven days, with no attestation and no release. A manual run needs the workflow file on the
default branch.

### build-release.ps1

```powershell
pwsh scripts/build-release.ps1 -JdkPath $jdk
```

[`build-release.ps1`](../../scripts/build-release.ps1) writes to
`artifacts/release/v<version>/`, which must not exist yet (`-OutputRoot` changes
`artifacts/release`). It:

1. refuses uncommitted changes to tracked files, so the package matches a commit
   (`-AllowUncommitted` is for trying the script)
2. publishes the app into `PzTools/` with a fresh `game-bridge-build/` folder, and checks
   that `PzTools.App.exe` carries the version
3. runs `PublishedDistributionTests` and the published-worker tests against that folder
4. packages `PzTools-v<version>-win-x64.zip` and its `.sha256`

A local build has no attestation. Attach its files to a release by hand only when CI
cannot build it.

### package-release.ps1

`build-release.ps1` calls it. On its own:

```powershell
pwsh scripts/package-release.ps1 -PublishDirectory artifacts/app-local -OutputArchive artifacts/PzTools-preview-win-x64.zip
```

[`package-release.ps1`](../../scripts/package-release.ps1):

- needs the archive's parent folder to exist and the archive to be outside the published
  folder, and refuses to replace an existing ZIP or `.sha256`
- adds [`START-HERE.txt`](../../build/START-HERE.txt) and puts everything under one folder,
  `-RootFolder` (`PzTools` by default; `build-release.ps1` uses `PzTools-v<version>`, so a
  new release extracts beside the old one)
- writes entries in a fixed order with fixed timestamps, so the same files give the same
  archive
- rejects links, and files that change while it runs
- reads every entry back and compares its SHA-256 before it writes the `.sha256`

It does not modify the input folder. Separate builds are not claimed to produce identical
binaries.

## CI

The [workflow](../../.github/workflows/windows.yml) has three jobs.

| Job | Runner | Runs |
| --- | --- | --- |
| `checks` | Linux | Always. Chooses what else runs ([`ci-plan.py`](../../scripts/ci-plan.py)), then `test-ci-plan.py`, `test-documentation-checker.py`, `check-documentation.py`, `check-localization.py`. Benchmarks when asked. |
| `windows` | Windows | One Release build with `-warnaserror`, an optional publication, an optional bridge fixture, then one `dotnet test --no-build` of `PzTools.Backup.Tests` |
| `release` | Windows | Tag pushes and **release_check** runs only, after `checks` and `windows` passed |

The UI smoke tests and the opt-in tests (real saves, USN, live game) never run in CI.

### When it runs

| Trigger | What runs |
| --- | --- |
| Pull request to `dev` or `main` | `checks`, and `windows` as the changed files require (below) |
| Push to a branch | Nothing. A change pushed without a pull request needs a manual run. |
| Tag `v*` | Everything: publication, bridge tests, then `release` |
| Manual run | `checks` and `windows`. **full** adds publication and bridge tests; **release_check** implies **full** and adds `release`; **benchmarks** alone runs only the Linux job with benchmarks. |

### What a pull request runs

[`ci-plan.py`](../../scripts/ci-plan.py) compares the pull request's merge commit with its
base.

| Changed files | Adds |
| --- | --- |
| Only `docs/`, `*.md`, `.gitignore`, `.gitattributes` | Nothing; the `windows` job is skipped |
| Anything else | The `windows` job, with `GameSaveClientTests` filtered out |
| `.github/`, `build/`, project and solution files, `global.json`, `config/defaults/`, `config/game-extensions/`, `scripts/publish-*`, `*.Cli`, `*.Runner`, `*.Scheduler` projects, tests named `*IntegrationTests*`, `*Distribution*`, `*StateStartup*` | Publication to `artifacts/ci-app`, with `PZTOOLS_DISTRIBUTION_DIR` and `PZTOOLS_TOOLS_DIR` set for the tests, plus everything in the next row |
| The bridge and extension projects, their tests and scripts, `Backup.Engine`, `Zomboid.Backup`, `Scheduling`, `Process.Hosting`, `Process.Contracts`, and a list of bridge test files | `test-game-bridge.ps1 -ReuseBuild -PrepareOnly`, and the bridge tests in the same test run |

Unknown paths count as code. NuGet packages are cached; build output is not. A newer push
to a pull request cancels the running one. TRX files are kept for seven days when a run
fails or published a distribution.

The job names `checks` and `windows` are what branch protection's required checks must
name.

### Tests that belong in the suite

Assert outcomes a user or the data can observe: restored bytes, retained revisions,
transactions and locks, configuration round trips, error classification, the game's
`save(true)` before capture. Do not pin private method text, XAML structure, grid rows,
translated prose or the number of supported languages. A UI layout or hover behaviour needs
a UI check, not a search for a substring in the source.

Use generous bounded waits so that a hang fails the test. On a shared runner, a process
finishing within two seconds is a diagnostic, not a correctness assertion.

## Documentation and localization checks

```powershell
python scripts/check-documentation.py
python scripts/test-documentation-checker.py
python scripts/check-localization.py
python scripts/test-ci-plan.py
```

`check-documentation.py` checks the Markdown under `docs/`, `README.md` and
`THIRD_PARTY_NOTICES.md` offline; it does not fetch external links.
`pwsh scripts/test-readme-links.ps1` runs the same checker. What it enforces is in
[documentation maintenance](documentation-maintenance.md). The localization check is
described in [localization](localization.md#checks).
