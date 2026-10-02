# Development and validation

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

This page is for contributors who build PZ Tools from source: how to set up a machine,
build and test, publish a runnable folder, package a release, and what the CI checks.
It is not about installing a release. The [user guide](../README.md) has the quick-start
commands; this page covers the full development workflow. All of it assumes a Windows
x64 development machine.

## Prerequisites

To build, install:

- the .NET SDK selected by [`global.json`](../global.json)
- PowerShell 7
- a Windows x64 Java 25 JDK
- the Visual Studio C++ and Windows/WinUI build tools

The projects restore the Windows App SDK and the managed dependencies themselves. The
game's trimmed Java runtime cannot be used as a build JDK. For the native build
requirements, and how `JdkPath`, `JAVA_HOME` and bundled toolchains are chosen, see
[bridge build prerequisites](save-bridge.md#building-and-publishing).

To run the published app, end users need the
[.NET 10 runtime for Windows x64](https://dotnet.microsoft.com/en-us/download/dotnet/10.0),
because the app is framework-dependent. The [app manifest](../src/PzTools.App/app.manifest)
requires administrator permission, for [USN tracking](glossary.md#usn-journal).

## Build and test

Run from the repository root. Replace the example path with your installed JDK:

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
```

The Java and native payload is part of the normal worker build. Do not copy old bridge
or worker binaries into a new app build.

**From Visual Studio**, F5 and Ctrl+F5 also build and stage the worker dependencies,
through [AppWorkers.targets](../build/AppWorkers.targets).

- `PZTOOLS_TOOLS_DIR` is an explicit development override. Remove it to use the normal
  bundled workers.
- Development runs use the same documented user data paths as an installed app. They
  are not kept apart from your local app configuration automatically.

## Publish a runnable folder

```powershell
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

[`publish-app.ps1`](../scripts/publish-app.ps1) calls
[`publish-tools.ps1`](../scripts/publish-tools.ps1) itself. Do not publish the tools to
that folder first and then run `publish-app.ps1` on the same, now nonempty, folder.

- **The output folder must be new or empty.** Use another `-Output` for the next
  publication. The scripts do not erase an existing installation or user settings.
- **Use a fresh `-SaveBridgeOutput` folder for a release** as well, so the Java payload
  does not reuse files from earlier development builds.

## Build a release

Raise `<Version>` in [`Directory.Build.props`](../Directory.Build.props) (every assembly
and executable carries it, and the Home page shows it), commit, then run:

```powershell
pwsh scripts/build-release.ps1 -JdkPath $jdk
```

[`build-release.ps1`](../scripts/build-release.ps1) does the steps below in one go and
writes to `artifacts/release/v<version>/`, which must not exist yet:

1. refuses uncommitted changes, so the package matches a commit
2. publishes the app into `PzTools/`, with a fresh Java build folder beside it, and
   checks that the published app carries the version
3. runs the tests that need a published folder (`PublishedDistributionTests` and the
   published-worker checks)
4. packages it as `PzTools-v<version>-win-x64.zip` with its `.sha256`, as below

Attach those two files to the GitHub release.

## Package a release

`build-release.ps1` runs this step itself. On its own, after testing a published folder:

```powershell
pwsh scripts/package-release.ps1 -PublishDirectory artifacts/app-local -OutputArchive artifacts/PzTools-preview-win-x64.zip
```

The archive's parent folder must already exist. The packager:

1. refuses output files that already exist
2. adds the short [release guide](../build/START-HERE.txt)
3. puts everything under a `PzTools/` top-level folder, with a fixed entry order and
   fixed timestamps
4. checks every file against its streamed SHA-256 before completing the ZIP and its
   `.sha256` sidecar
5. rejects links, and input files that change while it runs

It does not publish anything and does not modify the input folder. Packaging the same
published files twice gives the same archive; see [limits](#limits) for what that does
not cover.

## What to distribute

Distribute the **whole output folder**: workers, defaults, WinUI components and the
reduced Java [Attach](glossary.md#attach) runtime. Users run `PzTools.App.exe`
from it, not a source-code archive or an EXE copied on its own. Game JAR files are not
redistributed.

Keep saves and backup [repositories](glossary.md#repository) outside the application
output. Do not use an installed app folder as a native build-output directory.

The [deployment layout](deployment-layout.md) describes app files, user settings and
backup data separately.

**Existing data and development builds.** Read the [repository format](repository-format.md)
before opening existing data with a development build. If the schema is incompatible:

- keep the old data you need
- choose a new empty backup folder
- never delete the game's `Zomboid/Saves`, and never remove just the metadata database
  from a repository

## Test the published folder

A normal unit-test run does not show that the published workers are present, or that the
app and the workers come from the same build. To check that, test a fresh publication:

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

The example clears its test-only environment overrides afterwards. If you already rely
on different values for them, use a separate PowerShell session.

## Synthetic game integration and opt-in tests

```powershell
pwsh scripts/test-save-bridge.ps1 -JdkPath $jdk
```

This script runs against an isolated synthetic JVM, not a real running game.

Real-game tests, tests on external save samples and elevated USN tests need explicit
setup. Before opting in, read the [verification report](history/verification-report.md)
and the script concerned. Do not run a command against your live save just to reproduce
a benchmark.

## Documentation and localization checks

The documentation checks need Python 3.10 or later and nothing else: they use only the
standard library and do not access saves or the network.

```powershell
python scripts/test-documentation-checker.py
python scripts/check-documentation.py
pwsh scripts/test-readme-links.ps1
python scripts/check-localization.py
```

The PowerShell entry point runs the same documentation checker. It checks the root
guide, the third-party notices and the Markdown under `docs/`, including section targets,
required guide topics and index coverage. [Documentation maintenance](documentation-maintenance.md)
explains what these tests do and do not establish.

## CLI and advanced settings

- [CLI commands](cli.md) lists the backup, restore, ZIP, verification and maintenance
  operations, and [configuration](configuration.md) their parameters. CLI examples with
  placeholder paths are not commands to run against a live save.
- The backup worker's defaults are in
  [`config/defaults/backup-worker/default.toml`](../config/defaults/backup-worker/default.toml).
  The default uses Brotli compression and xxHash64 pack checksums. Content deduplication
  uses full SHA-256 and is optional.
- Change-detection fingerprints, copy verification and pack checksums have different
  purposes; they are not interchangeable safety switches. See
  [stable capture](stable-capture.md) and the [repository format](repository-format.md).
- For tuning individual components, see
  [advanced runtime configuration](runtime-configuration.md).

Old performance and verification results stay tied to the data, machines and commits
they state. The [documentation index](README.md#measurements-and-history) keeps those
records apart from the current user instructions.

## Limits

- **Publishing is not installing.** The publish workflow produces a runnable folder.
  Installation, code signing and a mode that runs without administrator permission are
  outside it.
- **Packaging is reproducible, builds are not claimed to be.** The same published files
  give the same archive. Separate builds with different toolchains are not claimed to
  produce identical binaries.
- **No automatic migration.** Incompatible repository schemas are not migrated.
- **Synthetic is not real.** The synthetic JVM tests do not exercise a real game.
- **A skipped test is not a passed test.**
- **Some checks need people.** Screenshot and layout checks, and native-speaker review,
  are separate from the automated resource checks.
- **Links are not fetched.** External URLs are counted but not fetched by the offline
  documentation check.

## CI

The [CI workflow](../.github/workflows/windows.yml) builds once, optionally publishes,
and then runs the applicable tests once with that fresh distribution. Check its result
for the exact commit.

### When it runs

| Trigger | What runs |
| --- | --- |
| A PR targeting `dev` or `main` | Validation chosen by the changed paths (below) |
| A push to `dev` or `main` | Nothing: branch pushes do not trigger CI, so the PR validation is not repeated |
| A release tag `v*` | Full validation |
| **CI / Run workflow / full=true** | Publication and synthetic JVM validation, whatever paths changed |
| A manual run with `benchmarks=true` | Benchmarks; a benchmark-only run uses Linux |

Benchmarks run only with `benchmarks=true`. A direct push to a branch without a PR
therefore needs a manual run before a release.

### What a PR runs

| Change | Jobs |
| --- | --- |
| Documentation only | One Linux job: documentation, localization and CI path selection |
| Code | The Linux job, plus one Windows job: one Release build, then one `dotnet test --no-build --no-restore` |
| Packaging, worker entry points, build or workflow | Also publishes a fresh distribution before that test run |
| Bridge or backup engine | Also prepares the synthetic JVM fixture from the existing Release bridge and runs those tests in the same test run |

There is no extra Debug build and no repeated full suite.

### Other CI rules

- Dependencies are cached; compiled outputs and user data are not.
- A superseded PR run is cancelled.
- TRX artifacts are kept for seven days for failed runs and publication runs. For a
  normal success, the counts are in the job log.
- CI enables no live-game, real-save or elevated-USN opt-in tests.
- A missing external prerequisite is reported as skipped, never as passed. A fixture
  that is explicitly configured but broken still fails.
- The workflow's check names are `checks` and `windows`. Required-check rules must match
  them; branch protection is not changed automatically.
- A skipped Windows job on a documentation-only PR is intentional.
- Running the workflow manually needs the workflow on the default branch. Until it is
  there, packaging PRs already exercise publication.

### Tests that belong in this suite

Assert observable outcomes:

- restored bytes and retained revisions
- transactions and locks
- configuration persistence
- error classification
- a game-thread `save(true)` before capture

Do not freeze private method text, handler spelling, XAML parent types, Grid row numbers,
translation prose, line-break counts or the current number of supported languages.
Resource keys, formatting arguments, .NET formatting and configuration round trips stay
covered. UI hover and layout behaviour needs a real UI check, not a check for a
substring in the source.

Keep generous bounded waits so that hangs are detected. A process finishing in under two
seconds is a diagnostic, not a reliable correctness assertion on a shared runner. The
product's own deadlines are unaffected.
