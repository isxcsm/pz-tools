<#
Asks the elevated launcher (register-elevated-launcher.ps1) to restart PZ Tools from a build folder under the
artifacts root, and waits for its answer. Runs without administrator rights.

    powershell -NoProfile -File scripts\dev\request-elevated-launch.ps1 -Build app-startup-18
    powershell -NoProfile -File scripts\dev\request-elevated-launch.ps1 -Build app-startup-18 -StopGame

-StopGame also closes Project Zomboid first (a Java change needs the game restarted). Prints the launcher's result
and exits 1 when it failed or did not answer within -TimeoutSeconds.
#>
param(
    [Parameter(Mandatory)][string]$Build,
    [switch]$StopGame,
    # The app may take up to a minute to stop work in progress before the launcher ends it.
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$exchange = Join-Path $env:LOCALAPPDATA 'PzToolsDev'
$resultPath = Join-Path $exchange 'result.json'
New-Item -ItemType Directory -Force -Path $exchange | Out-Null
$id = [guid]::NewGuid().ToString('N')
(@{ id = $id; build = $Build; stopGame = [bool]$StopGame } | ConvertTo-Json) |
    Set-Content -LiteralPath (Join-Path $exchange 'request.json') -Encoding UTF8

& schtasks.exe /Run /TN '\PzToolsDev\ElevatedLaunch' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not start the task \PzToolsDev\ElevatedLaunch. Is it registered?' }

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $resultPath) {
        $result = $null
        try { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } catch { }
        if ($result -and $result.id -eq $id) {
            Write-Host $result.message
            if (-not $result.ok) { exit 1 }
            exit 0
        }
    }
    Start-Sleep -Milliseconds 500
}
Write-Host "No answer from the launcher within $TimeoutSeconds seconds."
exit 1
