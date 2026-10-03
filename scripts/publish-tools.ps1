param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',
    [string] $Output = 'artifacts/tools',
    [string] $DotNetPath,
    [string] $JdkPath,
    [string] $GameBridgeOutput
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($GameBridgeOutput)) { $GameBridgeOutput = "artifacts/game-bridge/$Configuration" }
$bridgePath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $GameBridgeOutput))
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Output))
if (Test-Path -LiteralPath $outputPath) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Container) -or
        @(Get-ChildItem -LiteralPath $outputPath -Force).Count -ne 0) {
        throw 'Publish output must be a new or empty directory. Choose -Output <new-directory>; existing installations and user settings are never cleaned automatically.'
    }
}
if ([string]::IsNullOrWhiteSpace($DotNetPath)) {
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -ne $dotnetCommand) {
        $DotNetPath = $dotnetCommand.Source
    }
    else {
        $candidates = @(
            $(if (-not [string]::IsNullOrWhiteSpace($env:DOTNET_ROOT)) {
                Join-Path $env:DOTNET_ROOT 'dotnet.exe'
            }),
            $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
                Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
            })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
        $DotNetPath = $candidates | Select-Object -First 1
    }
}
if ([string]::IsNullOrWhiteSpace($DotNetPath) -or -not (Test-Path -LiteralPath $DotNetPath -PathType Leaf)) {
    throw 'dotnet 실행 파일을 찾을 수 없습니다. -DotNetPath로 경로를 지정하십시오.'
}
$dotnet = [System.IO.Path]::GetFullPath($DotNetPath)
$bridgeProperties = @("-p:GameBridgeDirectory=$bridgePath")
if (-not [string]::IsNullOrWhiteSpace($JdkPath)) { $bridgeProperties += "-p:JdkPath=$JdkPath" }
$projects = @(
    'src/PzTools.Backup.Cli/PzTools.Backup.Cli.csproj',
    'src/PzTools.Maintenance.Cli/PzTools.Maintenance.Cli.csproj',
    'src/PzTools.State.Collector.Cli/PzTools.State.Collector.Cli.csproj',
    'src/PzTools.State.Reactor.Cli/PzTools.State.Reactor.Cli.csproj',
    'src/PzTools.Backup.Runner/PzTools.Backup.Runner.csproj',
    'src/PzTools.Maintenance.Runner/PzTools.Maintenance.Runner.csproj',
    'src/PzTools.State.Runner/PzTools.State.Runner.csproj',
    'src/PzTools.Backup.Scheduler/PzTools.Backup.Scheduler.csproj',
    'src/PzTools.State.Scheduler/PzTools.State.Scheduler.csproj',
    'src/PzTools.Zomboid.Archive.Cli/PzTools.Zomboid.Archive.Cli.csproj',
    'src/PzTools.Zomboid.Recovery.Cli/PzTools.Zomboid.Recovery.Cli.csproj',
    'src/PzTools.Profiler.Cli/PzTools.Profiler.Cli.csproj'
)

foreach ($project in $projects) {
    # Shared projects are also restored by the app/test graphs without this RID.
    # Re-evaluate restore inputs so a previous graph cannot leave stale assets.
    & $dotnet publish (Join-Path $repositoryRoot $project) -c $Configuration `
        -r win-x64 --self-contained false --force -p:CopyOutputSymbolsToPublishDirectory=false `
        -o $outputPath @bridgeProperties
    if ($LASTEXITCODE -ne 0) {
        throw "게시 실패: $project"
    }
}

$defaultsSource = Join-Path $repositoryRoot 'config/defaults'
$defaultsTarget = Join-Path $outputPath 'defaults'
if (Test-Path -LiteralPath $defaultsSource -PathType Container) {
    New-Item -ItemType Directory -Path $defaultsTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $defaultsSource '*') -Destination $defaultsTarget -Recurse -Force
}

Write-Host "도구 게시 완료: $outputPath"
