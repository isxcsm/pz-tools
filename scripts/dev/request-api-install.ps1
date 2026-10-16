<#
Asks the elevated launcher (register-elevated-launcher.ps1) to run the PZ Extension API's installer, which needs
administrator rights, and waits for its answer. Runs without administrator rights, so testing the API needs no UAC
prompt per reinstall.

    powershell -NoProfile -File scripts\dev\request-api-install.ps1                 install (or reinstall)
    powershell -NoProfile -File scripts\dev\request-api-install.ps1 -Command status
    powershell -NoProfile -File scripts\dev\request-api-install.ps1 -Command uninstall -StopGame

The launcher runs pzext-install.jar from the API's release build folder (extension-api\out\release, build it first)
on the game folder, both fixed at registration. -StopGame closes Project Zomboid first: a running game holds the files
the installer replaces. Prints the installer's output and exits 1 when it failed or the launcher did not answer within
-TimeoutSeconds.
#>
param(
    [ValidateSet('install', 'uninstall', 'status')][string]$Command = 'install',
    [switch]$StopGame,
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$exchange = Join-Path $env:LOCALAPPDATA 'PzToolsDev'
$resultPath = Join-Path $exchange 'result.json'
New-Item -ItemType Directory -Force -Path $exchange | Out-Null
$id = [guid]::NewGuid().ToString('N')
(@{ id = $id; api = $Command; stopGame = [bool]$StopGame } | ConvertTo-Json) |
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
            if ($result.ok) { exit 0 }
            # A launcher registered before this request existed takes it for an app restart without a build.
            if ($result.message -like 'Not a build folder name*') {
                Write-Host 'The registered launcher predates API requests: run register-elevated-launcher.ps1 again from an administrator PowerShell.'
            }
            exit 1
        }
    }
    Start-Sleep -Milliseconds 500
}
Write-Host "No answer from the launcher within $TimeoutSeconds seconds."
exit 1
