param(
    [Parameter(Mandatory=$true)][string] $JdkPath,
    [string] $GameBridgeOutput,
    [ValidateSet('Debug', 'Release')][string] $Configuration = 'Debug',
    [switch] $ReuseBuild,
    [switch] $PrepareOnly,
    [switch] $CheckIncrementalBuild
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($GameBridgeOutput)) { $GameBridgeOutput = "artifacts/game-bridge/$Configuration" }
$bridgeRoot = Join-Path $repositoryRoot $GameBridgeOutput
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
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -d $fixtureOutput @sources
if ($LASTEXITCODE -ne 0) { throw 'Bridge fixture compilation failed' }
& (Join-Path $JdkPath 'bin/jar.exe') --create --file (Join-Path $fixtureOutput 'inspector.jar') --manifest (Join-Path $repositoryRoot 'tests/game-bridge/INSPECTOR.MF') -C $fixtureOutput bridgefixture
if ($LASTEXITCODE -ne 0) { throw 'Bridge inspector packaging failed' }
$env:PZTOOLS_GAME_BRIDGE_DIR = $bridgeRoot
$env:PZTOOLS_BRIDGE_TEST_JAVA = Join-Path $JdkPath 'bin/java.exe'
$env:PZTOOLS_BRIDGE_TEST_CLASSES = $fixtureOutput
& (Join-Path $PSScriptRoot 'test-game-extensions.ps1') -JdkPath $JdkPath -Configuration $Configuration -BridgeDirectory $bridgeRoot
$controlClasspath = @($fixtureOutput, (Join-Path $bridgeRoot 'pztools-game-bridge.jar'), (Join-Path $bridgeRoot 'pztools-game-bootstrap.jar'), (Join-Path $bridgeRoot 'extensions/pztools-extension-runtime.jar')) -join ';'
$controlSources = @(Get-ChildItem (Join-Path $repositoryRoot 'tests/extension-control') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp $controlClasspath -d $fixtureOutput @controlSources
if ($LASTEXITCODE -ne 0) { throw 'Continuous control protocol fixture compilation failed' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp $controlClasspath pztools.bridge.runtime.ExtensionControlTest
if ($LASTEXITCODE -ne 0) { throw 'Continuous control protocol tests failed' }
# A game runtime without the flight recorder: profiling must fail alone, never the state observer.
& (Join-Path $JdkPath 'bin/java.exe') --limit-modules java.base,java.instrument -ea -cp $controlClasspath pztools.bridge.runtime.ProfileFramesTest
if ($LASTEXITCODE -ne 0) { throw 'Profiler isolation tests failed' }
# The rolling recording in a real flight recorder: saves, cuts to its window, runs beside a recording asked for.
& (Join-Path $JdkPath 'bin/java.exe') --enable-native-access=ALL-UNNAMED -ea -cp $controlClasspath pztools.bridge.runtime.ProfileRollingTest
if ($LASTEXITCODE -ne 0) { throw 'Rolling recording tests failed' }
# The startup loader: install into a synthetic game's jar, start that game, update, reinstall, uninstall.
$startupOutput = Join-Path $fixtureOutput 'startup-loader'
New-Item -ItemType Directory -Path (Join-Path $startupOutput 'game') -Force | Out-Null
$startupGame = @(Get-ChildItem (Join-Path $repositoryRoot 'tests/startup-loader/game') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -d (Join-Path $startupOutput 'game') @startupGame
if ($LASTEXITCODE -ne 0) { throw 'Startup loader game fixture compilation failed' }
$startupJar = Join-Path $startupOutput 'projectzomboid.jar'
& (Join-Path $JdkPath 'bin/jar.exe') --create --file $startupJar -C (Join-Path $startupOutput 'game') zombie
if ($LASTEXITCODE -ne 0) { throw 'Startup loader game fixture packaging failed' }
$startupClasspath = @($startupOutput, (Join-Path $bridgeRoot 'pztools-game-bridge.jar')) -join ';'
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp $startupClasspath -d $startupOutput (Join-Path $repositoryRoot 'tests/startup-loader/pztools/bridge/StartupInstallTest.java')
if ($LASTEXITCODE -ne 0) { throw 'Startup loader test compilation failed' }
# The install runs on the app's own runtime, which has only the modules the bridge needs.
& (Join-Path $bridgeRoot 'runtime/bin/java.exe') -ea -cp $startupClasspath pztools.bridge.StartupInstallTest $startupJar $bridgeRoot (Join-Path $JdkPath 'bin/java.exe')
if ($LASTEXITCODE -ne 0) { throw 'Startup loader tests failed' }
# The CI caller runs the entire applicable suite once with these environment values.
if ($PrepareOnly) { return }
$arguments = @('test', (Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj'),
    '-c', $Configuration, '--filter', 'FullyQualifiedName~GameSaveClientTests', '--verbosity', 'minimal',
    '--logger', 'trx;LogFileName=game-bridge.trx', '--results-directory', (Join-Path $fixtureOutput 'results'))
if ($ReuseBuild) { $arguments += @('--no-build', '--no-restore') }
dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw 'Game bridge tests failed' }
