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
. (Join-Path $PSScriptRoot 'elevated-request.ps1')
Invoke-ElevatedRequest @{ build = $Build; stopGame = [bool]$StopGame } $TimeoutSeconds
