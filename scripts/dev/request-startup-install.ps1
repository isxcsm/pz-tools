<#
Asks the elevated launcher (register-elevated-launcher.ps1) to run the app's startup loader install tool from a build
folder, as the app (which runs elevated) does from its Game extensions page, and waits for its answer. Runs without
administrator rights: the install folder belongs to the administrators, so the tool refuses to change it without them.

    powershell -NoProfile -File scripts\dev\request-startup-install.ps1 -Build app-startup-18
    powershell -NoProfile -File scripts\dev\request-startup-install.ps1 -Build app-startup-18 -Command status
    powershell -NoProfile -File scripts\dev\request-startup-install.ps1 -Build app-startup-18 -Command uninstall -StopGame

The launcher runs pztools.bridge.StartupInstall from <artifacts root>\<Build>\game-bridge with that build's Java, on
the game folder fixed at registration. -StopGame closes Project Zomboid first. Prints the tool's output and exits 1 when
it failed or the launcher did not answer within -TimeoutSeconds.
#>
param(
    [Parameter(Mandatory)][string]$Build,
    [ValidateSet('install', 'uninstall', 'status', 'refresh')][string]$Command = 'install',
    [switch]$StopGame,
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'elevated-request.ps1')
Invoke-ElevatedRequest @{ startup = $Command; build = $Build; stopGame = [bool]$StopGame } $TimeoutSeconds 'StartupInstall'
