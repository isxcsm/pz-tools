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
. (Join-Path $PSScriptRoot 'elevated-request.ps1')
Invoke-ElevatedRequest @{ api = $Command; stopGame = [bool]$StopGame } $TimeoutSeconds 'pzext-install'
