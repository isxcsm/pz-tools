param(
    [Parameter(Mandatory=$true)][string] $JdkPath,
    [string] $GameBridgeOutput,
    [ValidateSet('Debug', 'Release')][string] $Configuration = 'Release',
    [switch] $ReuseBuild,
    # Every suite but dotnet, leaving the test variables set in the session for a dotnet test run after.
    [switch] $PrepareOnly,
    [switch] $CheckIncrementalBuild,
    # The suites to run; all by default. See docs/contributing/development.md#game-bridge-tests for which code each covers.
    [ValidateSet('extensions', 'control', 'profiler', 'startup', 'dotnet')][string[]] $Suite,
    # The dotnet suite's test filter, in place of the bridge tests (GameSaveClientTests).
    [string] $DotnetFilter = 'FullyQualifiedName~GameSaveClientTests'
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($GameBridgeOutput)) { $GameBridgeOutput = "artifacts/game-bridge/$Configuration" }
$bridgeRoot = Join-Path $repositoryRoot $GameBridgeOutput
$java = Join-Path $JdkPath 'bin/java.exe'
$javac = Join-Path $JdkPath 'bin/javac.exe'
$jar = Join-Path $JdkPath 'bin/jar.exe'
if (-not $Suite) { $Suite = @('extensions', 'control', 'profiler', 'startup', 'dotnet') }
if ($PrepareOnly) { $Suite = @($Suite | Where-Object { $_ -ne 'dotnet' }) }

# Preparation, shared by every suite: the bridge, the synthetic game, the fixture modules and the test variables.
if (-not $ReuseBuild) {
    & (Join-Path $PSScriptRoot 'build-game-bridge.ps1') -JdkPath $JdkPath -Output $GameBridgeOutput -Configuration $Configuration
}
$buildOutputs = @('pztools-game-bridge.jar', 'pztools-game-bootstrap.jar', 'pztools-attach-bootstrap.dll', 'runtime-built.txt')
foreach ($name in $buildOutputs) {
    if (-not (Test-Path -LiteralPath (Join-Path $bridgeRoot $name) -PathType Leaf)) {
        throw "Missing current build output: $name. Build the solution before using -ReuseBuild."
    }
}
# Build-system idempotence is an explicit diagnostic, not a second build on every test.
if ($CheckIncrementalBuild) {
    $buildTimes = @{}
    foreach ($name in $buildOutputs) { $buildTimes[$name] = (Get-Item -LiteralPath (Join-Path $bridgeRoot $name)).LastWriteTimeUtc }
    & (Join-Path $PSScriptRoot 'build-game-bridge.ps1') -JdkPath $JdkPath -Output $GameBridgeOutput -Configuration $Configuration
    foreach ($name in $buildOutputs) {
        if ((Get-Item -LiteralPath (Join-Path $bridgeRoot $name)).LastWriteTimeUtc -ne $buildTimes[$name]) {
            throw "An unchanged bridge build unexpectedly rewrote $name"
        }
    }
}
$fixtureOutput = Join-Path $repositoryRoot 'artifacts/game-bridge-tests'
New-Item -ItemType Directory -Path $fixtureOutput -Force | Out-Null
$sources = Get-ChildItem (Join-Path $repositoryRoot 'tests/game-bridge') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName
& $javac --release 25 -encoding UTF-8 -d $fixtureOutput @sources
if ($LASTEXITCODE -ne 0) { throw 'Bridge fixture compilation failed' }
& $jar --create --file (Join-Path $fixtureOutput 'inspector.jar') --manifest (Join-Path $repositoryRoot 'tests/game-bridge/INSPECTOR.MF') -C $fixtureOutput bridgefixture
if ($LASTEXITCODE -ne 0) { throw 'Bridge inspector packaging failed' }
$env:PZTOOLS_GAME_BRIDGE_DIR = $bridgeRoot
$env:PZTOOLS_BRIDGE_TEST_JAVA = $java
$env:PZTOOLS_BRIDGE_TEST_CLASSES = $fixtureOutput
# Sets PZTOOLS_EXTENSION_FIXTURE_JAR and PZTOOLS_CONTINUOUS_FIXTURE_JAR.
& (Join-Path $PSScriptRoot 'test-game-extensions.ps1') -JdkPath $JdkPath -Configuration $Configuration -BridgeDirectory $bridgeRoot -FixturesOnly

$controlClasspath = @($fixtureOutput, (Join-Path $bridgeRoot 'pztools-game-bridge.jar'), (Join-Path $bridgeRoot 'pztools-game-bootstrap.jar'), (Join-Path $bridgeRoot 'extensions/pztools-extension-runtime.jar')) -join ';'
$startupOutput = Join-Path $fixtureOutput 'startup-loader'
$compiled = @{}
# The control and profiler tests share their sources.
function Build-ControlTests {
    if ($compiled.control) { return }
    $controlSources = @(Get-ChildItem (Join-Path $repositoryRoot 'tests/extension-control') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
    & $javac --release 25 -encoding UTF-8 -cp $controlClasspath -d $fixtureOutput @controlSources
    if ($LASTEXITCODE -ne 0) { throw 'Extension control test compilation failed' }
    $compiled.control = $true
}
# The startup loader's synthetic game, which the extension API tests use too.
function Build-StartupGame {
    if ($compiled.startup) { return }
    New-Item -ItemType Directory -Path (Join-Path $startupOutput 'game') -Force | Out-Null
    $startupGame = @(Get-ChildItem (Join-Path $repositoryRoot 'tests/startup-loader/game') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
    & $javac --release 25 -encoding UTF-8 -d (Join-Path $startupOutput 'game') @startupGame
    if ($LASTEXITCODE -ne 0) { throw 'Startup loader game fixture compilation failed' }
    $compiled.startup = $true
}
function Invoke-Java([string] $failure, [string[]] $arguments) {
    & $java @arguments
    if ($LASTEXITCODE -ne 0) { throw $failure }
}

$suites = [ordered]@{
    # The extension runtime, the vehicle extension and its models.
    extensions = {
        & (Join-Path $PSScriptRoot 'test-game-extensions.ps1') -JdkPath $JdkPath -Configuration $Configuration -BridgeDirectory $bridgeRoot
    }
    # The app's and the resident controller's control of the extensions.
    control = {
        Build-ControlTests
        Invoke-Java 'Extension control tests failed' @('-ea', '-cp', $controlClasspath, 'pztools.bridge.runtime.ExtensionControlTest')
    }
    profiler = {
        Build-ControlTests
        # A game runtime without the flight recorder: profiling must fail alone, never the state observer.
        Invoke-Java 'Profiler isolation tests failed' @('--limit-modules', 'java.base,java.instrument', '-ea', '-cp', $controlClasspath, 'pztools.bridge.runtime.ProfileFramesTest')
        # The rolling recording in a real flight recorder: saves, cuts to its window, runs beside a recording asked for.
        Invoke-Java 'Rolling recording tests failed' @('--enable-native-access=ALL-UNNAMED', '-ea', '-cp', $controlClasspath, 'pztools.bridge.runtime.ProfileRollingTest')
    }
    # The startup loader: install into a synthetic game's jar, start that game, update, reinstall, uninstall.
    startup = {
        Build-StartupGame
        $startupJar = Join-Path $startupOutput 'projectzomboid.jar'
        & $jar --create --file $startupJar -C (Join-Path $startupOutput 'game') zombie
        if ($LASTEXITCODE -ne 0) { throw 'Startup loader game fixture packaging failed' }
        $startupClasspath = @($startupOutput, (Join-Path $bridgeRoot 'pztools-game-bridge.jar')) -join ';'
        & $javac --release 25 -encoding UTF-8 -cp $startupClasspath -d $startupOutput (Join-Path $repositoryRoot 'tests/startup-loader/pztools/bridge/StartupInstallTest.java')
        if ($LASTEXITCODE -ne 0) { throw 'Startup loader test compilation failed' }
        # Stands in for the app's helper getting into a game before the startup loader does.
        $attachFirstClasses = Join-Path $startupOutput 'attach-first'
        & $javac --release 25 -encoding UTF-8 -d $attachFirstClasses (Join-Path $repositoryRoot 'tests/startup-loader/attach-first/pztools/attachfirst/AttachFirst.java')
        if ($LASTEXITCODE -ne 0) { throw 'Attach-first agent compilation failed' }
        $attachFirstJar = Join-Path $startupOutput 'attach-first.jar'
        & $jar --create --file $attachFirstJar --manifest (Join-Path $repositoryRoot 'tests/startup-loader/attach-first/ATTACH-FIRST.MF') -C $attachFirstClasses pztools
        if ($LASTEXITCODE -ne 0) { throw 'Attach-first agent packaging failed' }
        # The shim's bytes do not depend on where or when it is built: the sources copied elsewhere and compiled again, with the
        # flags the bridge project uses, give the very classes the bridge jar carries (StartupInstallTest pins their SHA-256).
        $shimAgain = Join-Path $startupOutput 'shim-again'
        Remove-Item -Recurse -Force $shimAgain -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $repositoryRoot 'src/PzTools.GameBridge.Agent/shim') (Join-Path $shimAgain 'src') -Recurse
        $shimSources = @(Get-ChildItem (Join-Path $shimAgain 'src') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
        & $javac --release 25 -g:none -proc:none -encoding UTF-8 -d (Join-Path $shimAgain 'classes') @shimSources
        if ($LASTEXITCODE -ne 0) { throw 'Startup loader shim compilation failed' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $bridgeArchive = [IO.Compression.ZipFile]::OpenRead((Join-Path $bridgeRoot 'pztools-game-bridge.jar'))
        try {
            $shimEntries = @($bridgeArchive.Entries | Where-Object { $_.FullName -like 'pztools/startup/*.class' })
            if ($shimEntries.Count -ne 2) { throw 'The bridge jar does not carry exactly the shim in pztools/startup' }
            foreach ($entry in $shimEntries) {
                $stream = $entry.Open(); $bytes = [IO.MemoryStream]::new(); $stream.CopyTo($bytes); $stream.Dispose()
                $built = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes.ToArray()))
                $rebuilt = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes((Join-Path $shimAgain "classes/$($entry.FullName)"))))
                if ($built -ne $rebuilt) { throw "The shim class $($entry.FullName) is not the same when built again" }
            }
        } finally { $bridgeArchive.Dispose() }
        # The install runs on the app's own runtime, which has only the modules the bridge needs.
        & (Join-Path $bridgeRoot 'runtime/bin/java.exe') -ea -cp $startupClasspath pztools.bridge.StartupInstallTest $startupJar $bridgeRoot $java $attachFirstJar
        if ($LASTEXITCODE -ne 0) { throw 'Startup loader tests failed' }
    }
    # The app's side against a synthetic JVM that imitates the game.
    dotnet = {
        $arguments = @('test', (Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj'),
            '-c', $Configuration, '--filter', $DotnetFilter, '--verbosity', 'minimal',
            '--logger', 'trx;LogFileName=game-bridge.trx', '--results-directory', (Join-Path $fixtureOutput 'results'))
        if ($ReuseBuild) { $arguments += @('--no-build', '--no-restore') }
        dotnet @arguments
        if ($LASTEXITCODE -ne 0) { throw 'Game bridge .NET tests failed' }
    }
}

# Every suite asked for runs, whatever an earlier one did; the table at the end says which failed.
$results = foreach ($name in $suites.Keys) {
    if ($name -notin $Suite) { continue }
    Write-Host "== $name"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # The suite's own output goes to the screen, not into the results.
    try { & $suites[$name] | Out-Host; $outcome = 'passed'; $detail = '' }
    catch { $outcome = 'FAILED'; $detail = $_.Exception.Message }
    [pscustomobject]@{ Suite = $name; Result = $outcome; Seconds = [int]$watch.Elapsed.TotalSeconds; Detail = $detail }
}
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAILED')
if ($failed.Count -gt 0) { throw "Game bridge suites failed: $(($failed | ForEach-Object Suite) -join ', ')" }
