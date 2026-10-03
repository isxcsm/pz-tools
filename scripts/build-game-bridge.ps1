param(
    [string] $JdkPath,
    [string] $Output,
    [ValidateSet('Debug', 'Release')][string] $Configuration = 'Debug',
    [string] $DotNetPath = 'dotnet'
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Output)) { $Output = "artifacts/game-bridge/$Configuration" }
$outputPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Output))
$buildArguments = @('msbuild', (Join-Path $repositoryRoot 'src/PzTools.GameBridge.Agent/PzTools.GameBridge.Agent.proj'),
    '-t:Build', '-verbosity:minimal', "-p:Configuration=$Configuration", "-p:GameBridgeDirectory=$outputPath")
if (-not [string]::IsNullOrWhiteSpace($JdkPath)) { $buildArguments += "-p:JdkPath=$JdkPath" }
& $DotNetPath @buildArguments
if ($LASTEXITCODE -ne 0) { throw 'Game bridge build failed' }
Write-Host "Game bridge ready: $outputPath"
