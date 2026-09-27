# Development and validation

[Documentation index](README.md) · [User guide](../README.md)

These instructions are for building the application, not installing a release.
Use a Windows x64 development machine. The [user guide](../README.md) has the
quick-start commands; this page covers the development workflow.

## Prerequisites

Install the .NET SDK selected by [`global.json`](../global.json), PowerShell 7,
a Windows x64 Java 25 JDK, and the Visual Studio C++ and Windows/WinUI build tools.
The Windows App SDK and managed dependencies are restored by the projects.
The game's trimmed Java runtime is not a substitute for a build JDK.
See [bridge build prerequisites](save-bridge.md#building-and-publishing) for native
build requirements and how `JdkPath`, `JAVA_HOME` and bundled toolchains are selected.

The published app is framework-dependent: end users need the
[.NET 10 runtime for Windows x64](https://dotnet.microsoft.com/en-us/download/dotnet/10.0).
The [app manifest](../src/PzTools.App/app.manifest) currently requires administrator
permission for USN tracking. The publish workflow produces a runnable folder;
installation, code signing and a lower-privilege mode are outside this workflow.

## Build and test

Run from the repository root. Replace the example path with your installed JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
```

The Java/native payload is part of the normal worker build graph. Do not copy old
bridge or worker binaries into a new app build. Visual Studio F5/Ctrl+F5 also builds
and stages worker dependencies through [AppWorkers.targets](../build/AppWorkers.targets).
`PZTOOLS_TOOLS_DIR` is an explicit development override; remove it for the normal
bundled-worker path. Development runs still use the documented user data paths;
they are not automatically isolated from your local app configuration.

## Publish a runnable folder

```powershell
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

[`publish-app.ps1`](../scripts/publish-app.ps1) already invokes
[`publish-tools.ps1`](../scripts/publish-tools.ps1). Do not publish tools to that
folder first and then call `publish-app.ps1` on the same nonempty folder.
The scripts require a **new or empty output folder**. Use another `-Output` for the
next publication; they do not erase an existing installation or user settings.

Distribute the **whole output folder**, including workers, defaults, WinUI components
and the reduced Java Attach runtime. Run `PzTools.App.exe`, not a source-code archive
or an EXE copied on its own. Game JAR files are not redistributed. Keep saves and
backup repositories outside the application output and do not use an installed app
folder as a native build-output directory.

The [deployment layout](deployment-layout.md) describes app files, user settings and
backup data separately. Consult the [repository format](repository-format.md) before
opening existing data with a pre-release build: incompatible schemas have no automatic
migration. Retain needed old data and choose a new empty backup folder, never delete
the game's `Zomboid/Saves` or remove just the metadata database from a repository.

## Test the published folder

A normal unit-test run does not prove that the published workers are present or
that the app and workers are from the same build. Use a fresh publication:

```powershell
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/app-local).Path
$env:PZTOOLS_TOOLS_DIR = $env:PZTOOLS_DISTRIBUTION_DIR
try {
    dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
    if ($LASTEXITCODE -ne 0) { throw 'Distribution tests failed.' }
}
finally {
    Remove-Item Env:PZTOOLS_DISTRIBUTION_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:PZTOOLS_TOOLS_DIR -ErrorAction SilentlyContinue
}
```

This example clears its test-only environment overrides afterward; use a separate
PowerShell session if you already rely on different values. The
[CI workflow](../.github/workflows/windows.yml) builds once, optionally publishes,
and then runs the applicable tests once with that fresh distribution. Check its
result for the exact commit.

## Synthetic game integration and opt-in tests

```powershell
pwsh scripts/test-save-bridge.ps1 -JdkPath $jdk
```

This script targets an isolated synthetic JVM, not a running real game. Real-game,
external-save-sample and elevated USN tests require explicit setup. Read the
[verification report](verification-report.md) and the applicable script before
opting in; do not run a command against your live save just to reproduce a benchmark.
A skipped test is not a passed test. Screenshot/layout checks and native-speaker
review are separate from automated resource checks.

## Documentation and localization checks

Python 3.10 or later is sufficient for the documentation checks; they use only the
standard library and do not access saves or the network:

```powershell
python scripts/test-documentation-checker.py
python scripts/check-documentation.py
pwsh scripts/test-readme-links.ps1
python scripts/check-localization.py
```

The PowerShell entry point delegates to the same documentation checker. It checks
the root guide, third-party notices and Markdown under `docs/`, including section
targets, required guide topics and index coverage. External URLs are counted but
are **not fetched** by this offline check. See the [documentation maintenance guide](documentation-maintenance.md) for
what these tests do and do not establish.

## CLI and advanced settings

See [CLI commands](cli.md) for the available backup, restore, ZIP, verification and
maintenance operations, and [configuration](configuration.md) for their parameters.
CLI examples with placeholder paths are not commands to run against a live save.

The backup worker's defaults are in
[`config/defaults/backup-worker/default.toml`](../config/defaults/backup-worker/default.toml).
The current default uses Brotli compression and xxHash64 pack checksums; content
deduplication uses full SHA-256 and is optional. Change-detection fingerprints,
copy verification and pack checksums have different purposes; see
[stable capture](stable-capture.md) and the [repository format](repository-format.md)
instead of treating them as interchangeable safety switches.

Use [advanced runtime configuration](runtime-configuration.md) for component tuning.
Old performance and verification results remain tied to their stated data, machines
and commits; the [documentation index](README.md#measurements-and-history) separates
those records from the current user instructions.

## CI

CI runs for PRs targeting `dev` or `main`; pushes to those branches do not repeat
the same PR validation. Release tags `v*` run full validation. Direct branch pushes
without a PR therefore require a manual run before release.

Documentation-only PRs run one Linux job for documentation, localization and CI path
selection. Code PRs add one Windows job: one Release build followed by one
`dotnet test --no-build --no-restore`. Packaging, worker entry-point, build and workflow
changes publish a fresh distribution before that test invocation. Bridge and backup-engine
changes prepare the synthetic JVM fixture using the existing Release bridge and run
those tests in the same invocation. There is no extra Debug build or repeated full suite.

Use **CI / Run workflow / full=true** for publication and synthetic JVM validation
regardless of changed paths. Release tags do the same.
Benchmarks run only with `benchmarks=true`; a benchmark-only manual run uses Linux.

Dependencies, not compiled outputs or user data, are cached. Superseded PR runs are
cancelled. TRX artifacts are kept seven days for failures or publication runs; normal
success counts remain in the job log. No live-game, real-save or elevated-USN opt-in
is enabled by CI. Missing external prerequisites are reported as skipped, never passed.
Explicitly configured but broken fixtures still fail.

### Tests that belong in this suite

Assert observable outcomes: restored bytes, retained revisions, transactions and locks,
configuration persistence, error classification and game-thread save(true) before capture.
Do not freeze private method text, handler spelling, XAML parent types, Grid row numbers,
translation prose, line-break counts or the current number of supported languages.
Resource keys, formatting arguments, .NET formatting and configuration round trips remain
covered. UI hover/layout behavior needs an actual UI check, not a source-substring proxy.
Keep generous bounded waits to detect hangs; sub-two-second process speed is diagnostic,
not a reliable correctness assertion on a shared runner. Product deadlines remain unchanged.

Workflow check names are `checks` and `windows`. Required-check rules must match them;
protection is not changed automatically. A skipped Windows job on a docs-only PR is
intentional. Workflow dispatch requires the workflow on the default branch; until then,
packaging PRs already exercise publication.
