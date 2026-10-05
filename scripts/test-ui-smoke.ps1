# Builds and runs the WinUI smoke tests: each opens real XAML in a hidden window, without the app host, the game or
# user data, and writes PASS or FAIL. They are not part of `dotnet test`, so run this after UI changes.
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',
    [string] $Output = 'artifacts/ui-smoke',
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Output))
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$strings = Join-Path $repositoryRoot 'src/PzTools.App/Strings'

# Each smoke takes its own arguments: a result file, or a folder it writes result.txt and renders into.
$smokes = @(
    @{ Name = 'TooltipSmoke'; Result = 'tooltip.txt'; Arguments = { param($result) , $result } },
    @{ Name = 'LocalizationSmoke'; Result = 'localization.txt'; Arguments = { param($result) $strings, $result } },
    @{ Name = 'LogsSmoke'; Result = 'logs/result.txt'; Arguments = { param($result) , (Split-Path -Parent $result) } },
    @{ Name = 'HomeSmoke'; Result = 'home/result.txt'; Arguments = { param($result) , (Split-Path -Parent $result) } },
    @{ Name = 'ExtensionsSmoke'; Result = 'extensions/result.txt'; Arguments = { param($result) , (Split-Path -Parent $result) } }
)

$failed = 0
foreach ($smoke in $smokes) {
    $project = Join-Path $repositoryRoot "tests/PzTools.$($smoke.Name)/PzTools.$($smoke.Name).csproj"
    dotnet build $project -c $Configuration -v q -nologo | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "$($smoke.Name): build failed"; $failed++; continue }
    $executable = Join-Path $repositoryRoot "tests/PzTools.$($smoke.Name)/bin/$Configuration/net10.0-windows10.0.19041.0/win-x64/PzTools.$($smoke.Name).exe"
    $result = Join-Path $outputRoot $smoke.Result
    if (Test-Path -LiteralPath $result) { Clear-Content -LiteralPath $result }
    $process = Start-Process -FilePath $executable -ArgumentList (& $smoke.Arguments $result) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        Write-Host "$($smoke.Name): no result within $TimeoutSeconds s"
        $failed++
        continue
    }
    $text = if (Test-Path -LiteralPath $result) { (Get-Content -LiteralPath $result -Raw) } else { '' }
    if ($process.ExitCode -eq 0 -and $text -like 'PASS*') { Write-Host "$($smoke.Name): $($text.Trim())" }
    else {
        Write-Host "$($smoke.Name): exit $($process.ExitCode) $($text.Trim())"
        $failed++
    }
}
if ($failed -ne 0) { throw "$failed of $($smokes.Count) UI smoke tests failed." }
Write-Host "All $($smokes.Count) UI smoke tests passed. Renders are in $outputRoot."
