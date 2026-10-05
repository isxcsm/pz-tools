param(
    [string] $SavesRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Zomboid\Saves'),
    # Without it, each run publishes to a new folder under artifacts/verify-a15: publish-app.ps1 never
    # publishes over an existing folder. With -SkipPublish, give the folder of an earlier run.
    [string] $Output,
    # Passed to publish-app.ps1; without it the build uses JAVA_HOME, then a single bundled jdk-25*.
    [string] $JdkPath,
    [string] $DotNetPath = 'C:\Program Files\dotnet\dotnet.exe',
    [switch] $SkipPublish,
    [switch] $SkipApp
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Output)) {
    if ($SkipPublish) { throw '-SkipPublish needs -Output: the folder an earlier run published to.' }
    $Output = "artifacts/verify-a15/$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Output))
$testProject = Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The A15 USN check must run in an administrator PowerShell.'
}

if (-not (Test-Path -LiteralPath $DotNetPath -PathType Leaf)) {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'Cannot find the dotnet executable. Give its path with -DotNetPath.'
    }
    $DotNetPath = $command.Source
}
$dotnet = [System.IO.Path]::GetFullPath($DotNetPath)

if (-not (Test-Path -LiteralPath $SavesRoot -PathType Container)) {
    throw "Cannot find the saves folder: $SavesRoot"
}
$resolvedSavesRoot = (Resolve-Path -LiteralPath $SavesRoot).Path

if (-not $SkipPublish) {
    & (Join-Path $PSScriptRoot 'publish-app.ps1') `
        -Configuration Release -Output $Output -DotNetPath $dotnet -JdkPath $JdkPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Publishing the Release app failed.'
    }
}

$appPath = Join-Path $outputPath 'PzTools.App.exe'
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
    throw "Cannot find the published app: $appPath"
}

$priorToolsDir = $env:PZTOOLS_TOOLS_DIR
$priorRealSavesRoot = $env:PZTOOLS_REAL_SAVES_ROOT
$priorUsn = $env:PZTOOLS_TEST_USN
try {
    $env:PZTOOLS_TOOLS_DIR = $outputPath
    $env:PZTOOLS_REAL_SAVES_ROOT = $resolvedSavesRoot
    $env:PZTOOLS_TEST_USN = '1'

    Write-Host 'Running the full Release tests and the real USN, save and published-process checks.'
    & $dotnet test $testProject -c Release --logger 'console;verbosity=minimal'
    if ($LASTEXITCODE -ne 0) {
        throw 'The A15 Release end-to-end tests failed.'
    }
}
finally {
    $env:PZTOOLS_TOOLS_DIR = $priorToolsDir
    $env:PZTOOLS_REAL_SAVES_ROOT = $priorRealSavesRoot
    $env:PZTOOLS_TEST_USN = $priorUsn
}

if (-not $SkipApp) {
    Write-Host ''
    Write-Host 'Starting the published app. Check the following before closing it.'
    Write-Host '  1. Switching languages, and the system, light and dark themes'
    Write-Host '  2. The wide three-pane layout, the narrow list/details switch, keyboard focus and clipping'
    Write-Host '  3. On starting play: the active overlay, the progress card and the next backup countdown'
    Write-Host '  4. After play ends: one final backup, then the save is released'
    Write-Host '  5. Manual backup, the restore dialog, archive import and export'
    Write-Host 'Close the app window when done. Leftover processes are checked after that.'

    $app = Start-Process -FilePath $appPath -PassThru
    Wait-Process -Id $app.Id
    Start-Sleep -Seconds 2

    $remaining = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'PzTools*' }
    if ($remaining) {
        $names = ($remaining | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', '
        throw "PZ Tools processes are left after the app closed: $names"
    }
    Write-Host 'No PZ Tools processes are left after the app closed.'
}

Write-Host 'The A15 automatic checks passed. Record the UI checklist results in the verification report.'
