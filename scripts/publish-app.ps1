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

# The list of the published files, with their sizes and SHA-256: the app checks its folder against it at start
# (InstallIntegrity), which tells a release extracted over another one while it ran. Written last, of the folder as
# published; it does not list itself.
$manifestName = 'pztools-files.txt'
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("PZTOOLS-FILES`t1")
$published = Get-ChildItem -LiteralPath $outputPath -Recurse -File -Force |
    ForEach-Object { [pscustomobject]@{ File = $_; Relative = $_.FullName.Substring($outputPath.TrimEnd('\').Length + 1).Replace('\', '/') } } |
    Where-Object { $_.Relative -cne $manifestName } |
    Sort-Object -Property Relative -CaseSensitive
foreach ($item in $published) {
    $hash = (Get-FileHash -LiteralPath $item.File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines.Add("$hash`t$($item.File.Length)`t$($item.Relative)")
}
[IO.File]::WriteAllText((Join-Path $outputPath $manifestName), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

Write-Host "PzTools 앱 게시 완료: $outputPath ($($published.Count) files listed)"
