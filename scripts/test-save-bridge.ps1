param(
    [Parameter(Mandatory=$true)][string] $JdkPath,
    [string] $SaveBridgeOutput,
    [ValidateSet('Debug', 'Release')][string] $Configuration = 'Debug',
    [switch] $ReuseBuild,
    [switch] $PrepareOnly,
    [switch] $CheckIncrementalBuild
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SaveBridgeOutput)) { $SaveBridgeOutput = "artifacts/save-bridge/$Configuration" }
$bridgeRoot = Join-Path $repositoryRoot $SaveBridgeOutput
if (-not $ReuseBuild) {
    & (Join-Path $PSScriptRoot 'build-save-bridge.ps1') -JdkPath $JdkPath -Output $SaveBridgeOutput -Configuration $Configuration
}
$buildOutputs = @('pztools-save-bridge.jar', 'pztools-save-bootstrap.jar', 'pztools-attach-bootstrap.dll', 'runtime-built.txt')
foreach ($name in $buildOutputs) {
    if (-not (Test-Path -LiteralPath (Join-Path $bridgeRoot $name) -PathType Leaf)) {
        throw "Missing current build output: $name. Build the solution before using -ReuseBuild."
    }
}
# Build-system idempotence is an explicit diagnostic, not a second build on every test.
if ($CheckIncrementalBuild) {
    $buildTimes = @{}
    foreach ($name in $buildOutputs) { $buildTimes[$name] = (Get-Item -LiteralPath (Join-Path $bridgeRoot $name)).LastWriteTimeUtc }
    & (Join-Path $PSScriptRoot 'build-save-bridge.ps1') -JdkPath $JdkPath -Output $SaveBridgeOutput -Configuration $Configuration
    foreach ($name in $buildOutputs) {
        if ((Get-Item -LiteralPath (Join-Path $bridgeRoot $name)).LastWriteTimeUtc -ne $buildTimes[$name]) {
            throw "An unchanged bridge build unexpectedly rewrote $name"
        }
    }
}
$fixtureOutput = Join-Path $repositoryRoot 'artifacts/save-bridge-tests'
New-Item -ItemType Directory -Path $fixtureOutput -Force | Out-Null
$sources = Get-ChildItem (Join-Path $repositoryRoot 'tests/save-bridge') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -d $fixtureOutput @sources
if ($LASTEXITCODE -ne 0) { throw 'Bridge fixture compilation failed' }
& (Join-Path $JdkPath 'bin/jar.exe') --create --file (Join-Path $fixtureOutput 'inspector.jar') --manifest (Join-Path $repositoryRoot 'tests/save-bridge/INSPECTOR.MF') -C $fixtureOutput bridgefixture
if ($LASTEXITCODE -ne 0) { throw 'Bridge inspector packaging failed' }
$env:PZTOOLS_SAVE_BRIDGE_DIR = $bridgeRoot
$env:PZTOOLS_BRIDGE_TEST_JAVA = Join-Path $JdkPath 'bin/java.exe'
$env:PZTOOLS_BRIDGE_TEST_CLASSES = $fixtureOutput
& (Join-Path $PSScriptRoot 'test-game-extensions.ps1') -JdkPath $JdkPath -Configuration $Configuration -BridgeDirectory $bridgeRoot
# The CI caller runs the entire applicable suite once with these environment values.
if ($PrepareOnly) { return }
$arguments = @('test', (Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj'),
    '-c', $Configuration, '--filter', 'FullyQualifiedName~GameSaveClientTests', '--verbosity', 'minimal',
    '--logger', 'trx;LogFileName=save-bridge.trx', '--results-directory', (Join-Path $fixtureOutput 'results'))
if ($ReuseBuild) { $arguments += @('--no-build', '--no-restore') }
dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw 'Save bridge tests failed' }
