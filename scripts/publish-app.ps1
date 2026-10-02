param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $Output = 'artifacts/app',
    [string] $DotNetPath = 'C:\Program Files\dotnet\dotnet.exe',
    [string] $JdkPath,
    [string] $GameBridgeOutput
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Output))
if (-not (Test-Path -LiteralPath $DotNetPath -PathType Leaf)) {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw 'dotnet 실행 파일을 찾을 수 없습니다.' }
    $DotNetPath = $command.Source
}

& (Join-Path $PSScriptRoot 'publish-tools.ps1') `
    -Configuration $Configuration -Output $Output -DotNetPath $DotNetPath -JdkPath $JdkPath -GameBridgeOutput $GameBridgeOutput
if ($LASTEXITCODE -ne 0) { throw 'worker 게시에 실패했습니다.' }

# Forward the same toolchain/output selection used by workers into the App dependency graph.
$publishProperties = @()
if (-not [string]::IsNullOrWhiteSpace($JdkPath)) { $publishProperties += "-p:JdkPath=$JdkPath" }
if (-not [string]::IsNullOrWhiteSpace($GameBridgeOutput)) {
    $bridgePath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $GameBridgeOutput))
    $publishProperties += "-p:GameBridgeDirectory=$bridgePath"
}
& $DotNetPath publish `
    (Join-Path $repositoryRoot 'src/PzTools.App/PzTools.App.csproj') `
    -c $Configuration -p:Platform=x64 -r win-x64 --self-contained false --force `
    -p:CopyOutputSymbolsToPublishDirectory=false -p:PzToolsDistribution=true -o $outputPath @publishProperties
if ($LASTEXITCODE -ne 0) { throw 'WinUI 앱 게시에 실패했습니다.' }

Write-Host "PzTools 앱 게시 완료: $outputPath"
