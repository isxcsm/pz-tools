param([Parameter(Mandatory=$true)][string] $JdkPath, [string] $SaveBridgeOutput = 'artifacts/save-bridge/Debug')
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build-save-bridge.ps1') -JdkPath $JdkPath -Output $SaveBridgeOutput
$bridgeRoot = Join-Path $repositoryRoot $SaveBridgeOutput
$buildOutputs = @('pztools-save-bridge.jar', 'pztools-save-bootstrap.jar', 'pztools-attach-bootstrap.dll', 'runtime-built.txt')
$buildTimes = @{}
foreach ($name in $buildOutputs) { $buildTimes[$name] = (Get-Item -LiteralPath (Join-Path $bridgeRoot $name)).LastWriteTimeUtc }
& (Join-Path $PSScriptRoot 'build-save-bridge.ps1') -JdkPath $JdkPath -Output $SaveBridgeOutput
foreach ($name in $buildOutputs) {
    if ((Get-Item -LiteralPath (Join-Path $bridgeRoot $name)).LastWriteTimeUtc -ne $buildTimes[$name]) {
        throw "An unchanged bridge build unexpectedly rewrote $name"
    }
}
Write-Host 'Incremental bridge build verified: no unchanged payloads were rewritten.'
$fixtureOutput = Join-Path $repositoryRoot 'artifacts/save-bridge-tests'
New-Item -ItemType Directory -Path $fixtureOutput -Force | Out-Null
$sources = Get-ChildItem (Join-Path $repositoryRoot 'tests/save-bridge') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -d $fixtureOutput @sources
if ($LASTEXITCODE -ne 0) { throw 'Bridge fixture compilation failed' }
& (Join-Path $JdkPath 'bin/jar.exe') --create --file (Join-Path $fixtureOutput 'inspector.jar') --manifest (Join-Path $repositoryRoot 'tests/save-bridge/INSPECTOR.MF') -C $fixtureOutput bridgefixture
if ($LASTEXITCODE -ne 0) { throw 'Bridge inspector packaging failed' }
$env:PZTOOLS_SAVE_BRIDGE_DIR = $bridgeRoot
$env:PZTOOLS_BRIDGE_TEST_JAVA = Join-Path $JdkPath 'bin/java.exe'
$env:PZTOOLS_BRIDGE_TEST_CLASSES = $fixtureOutput
 dotnet test (Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj') `
    --filter 'FullyQualifiedName~GameSaveClientTests' --verbosity minimal `
    --logger 'trx;LogFileName=save-bridge.trx' --results-directory (Join-Path $fixtureOutput 'results')
if ($LASTEXITCODE -ne 0) { throw 'Save bridge tests failed' }
