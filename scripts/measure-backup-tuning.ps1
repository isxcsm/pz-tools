param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Plan,
    [Parameter(Mandatory)][string]$Output,
    [ValidateSet('initial', 'fallback')][string]$Scenario = 'initial',
    [string]$SeedRepository,
    [ValidateRange(1, 20)][int]$Repeats = 3,
    [int]$OrderSeed = 1729,
    [string]$Benchmark = (Join-Path $PSScriptRoot '../src/PzTools.Backup.Benchmarks/bin/Release/net10.0-windows/PzTools.Backup.Benchmarks.exe')
)

$ErrorActionPreference = 'Stop'
$benchmarkPath = (Resolve-Path -LiteralPath $Benchmark).Path
$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$planPath = (Resolve-Path -LiteralPath $Plan).Path
$outputPath = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $outputPath) { throw 'Use a fresh output directory; previous measurements are never overwritten.' }
if ($Scenario -eq 'fallback' -and !$SeedRepository) { throw 'Fallback requires an initial synthetic seed repository.' }
if ($SeedRepository) { $SeedRepository = (Resolve-Path -LiteralPath $SeedRepository).Path }
foreach ($inputDirectory in @($sourcePath, $SeedRepository) | Where-Object { $_ }) {
    $inputRoot = [IO.Path]::TrimEndingDirectorySeparator($inputDirectory)
    $outputRoot = [IO.Path]::TrimEndingDirectorySeparator($outputPath)
    if ($inputRoot.Equals($outputRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $outputRoot.StartsWith($inputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $inputRoot.StartsWith($outputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output must not overlap the source or seed repository.'
    }
}
$definition = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable
if (!$definition.cases -or !$definition.base) { throw 'Plan must contain base runtime values and named cases.' }
foreach ($name in $definition.cases.Keys) {
    if ($name -notmatch '^[a-z][a-z0-9-]*$') { throw "Invalid case name: $name" }
}
New-Item -ItemType Directory -Path $outputPath | Out-Null
Copy-Item -LiteralPath $planPath -Destination (Join-Path $outputPath 'plan.json')

# These are generated benchmark inputs, not the installed user's configuration.
$configs = @{}
foreach ($name in $definition.cases.Keys) {
    $runtime = [ordered]@{}
    foreach ($key in $definition.base.Keys) { $runtime[$key] = $definition.base[$key] }
    foreach ($key in $definition.cases[$name].Keys) { $runtime[$key] = $definition.cases[$name][$key] }
    $lines = @('format_version = 1', '[runtime]')
    foreach ($key in $runtime.Keys) {
        if ($key -notmatch '^[a-z_]+$' -or $runtime[$key] -isnot [long] -and $runtime[$key] -isnot [int]) {
            throw 'Tuning inputs must be integer runtime settings.'
        }
        $lines += "$key = $($runtime[$key])"
    }
    $configs[$name] = Join-Path $outputPath "$name.toml"
    [IO.File]::WriteAllLines($configs[$name], $lines)
}

$results = [Collections.Generic.List[object]]::new()
$order = [Collections.Generic.List[object]]::new()
for ($round = 1; $round -le $Repeats; $round++) {
    $random = [Random]::new($OrderSeed + $round)
    $names = @($definition.cases.Keys | Sort-Object { $random.Next() })
    foreach ($name in $names) {
        $runPath = Join-Path $outputPath ("r{0:d2}-{1}" -f $round, $name)
        $arguments = @('--tune', '--source', $sourcePath, '--config', $configs[$name],
            '--scenario', $Scenario, '--output', $runPath)
        if ($SeedRepository) { $arguments += @('--seed-repository', $SeedRepository) }
        $log = & $benchmarkPath @arguments 2>&1
        $exitCode = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $outputPath ("r{0:d2}-{1}.log" -f $round, $name)), [string[]]$log)
        if ($exitCode -ne 0) { throw "Benchmark failed: $name round $round (exit $exitCode): $log" }
        $result = Get-Content -LiteralPath (Join-Path $runPath 'metrics.json') -Raw | ConvertFrom-Json -AsHashtable
        $result['case'] = $name
        $result['round'] = $round
        $results.Add($result)
        $order.Add(@{ round = $round; name = $name; output = $runPath })
        [IO.File]::WriteAllText((Join-Path $outputPath 'results.json'), (ConvertTo-Json -InputObject $results.ToArray() -Depth 12))
        [IO.File]::WriteAllText((Join-Path $outputPath 'order.json'), (ConvertTo-Json -InputObject $order.ToArray() -Depth 4))
        Write-Host ("{0} r{1} {2}: total={3:N0} ms; plan/scan={4:N0}; capture={5:N0}; CPU={6:N0}; peak={7:N1} MiB" -f
            $Scenario, $round, $name, $result.totalMilliseconds, $result.scanOrPlanningMilliseconds,
            $result.captureMilliseconds, $result.cpuMilliseconds, ($result.peakWorkingSetBytes / 1MB))
    }
}

function Median([object[]]$Values) {
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}
$summary = foreach ($name in $definition.cases.Keys) {
    $runs = @($results | Where-Object { $_.case -eq $name })
    [ordered]@{
        case = $name; runs = $runs.Count
        medianTotalMs = Median @($runs | ForEach-Object { $_.totalMilliseconds })
        medianScanOrPlanningMs = Median @($runs | ForEach-Object { $_.scanOrPlanningMilliseconds })
        medianCaptureMs = Median @($runs | ForEach-Object { $_.captureMilliseconds })
        medianCpuMs = Median @($runs | ForEach-Object { $_.cpuMilliseconds })
        medianAllocatedMiB = (Median @($runs | ForEach-Object { $_.allocatedBytes })) / 1MB
        medianPeakMiB = (Median @($runs | ForEach-Object { $_.peakWorkingSetBytes })) / 1MB
        minTotalMs = ($runs | ForEach-Object { $_.totalMilliseconds } | Measure-Object -Minimum).Minimum
        maxTotalMs = ($runs | ForEach-Object { $_.totalMilliseconds } | Measure-Object -Maximum).Maximum
    }
}
[IO.File]::WriteAllText((Join-Path $outputPath 'summary.json'), (ConvertTo-Json -InputObject @($summary) -Depth 4))
$summary | ForEach-Object { [pscustomobject]$_ } | Sort-Object medianTotalMs | Format-Table -AutoSize
