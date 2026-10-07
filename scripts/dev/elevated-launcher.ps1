<#
Restarts PZ Tools from a chosen build folder with administrator rights, for development on this computer.

The scheduled task that register-elevated-launcher.ps1 registers runs this script with the highest privileges, so an
agent or script running without them can swap the app build (request-elevated-launch.ps1) without a UAC prompt.
register-elevated-launcher.ps1 copies it to an administrators-only folder; the copy there is the one that runs.

It reads one request, %LOCALAPPDATA%\PzToolsDev\request.json:
    { "id": "...", "build": "app-startup-18", "stopGame": false }
"build" is a folder name directly under the artifacts root fixed at registration (launcher.json beside this
script). It closes the running app and its worker processes, closes Project Zomboid when stopGame is true, starts
<root>\<build>\PzTools.App.exe and writes %LOCALAPPDATA%\PzToolsDev\result.json with the request's id.

Windows PowerShell 5.1 runs it: no PowerShell 7 syntax.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exchange = Join-Path $env:LOCALAPPDATA 'PzToolsDev'
$requestPath = Join-Path $exchange 'request.json'
$resultPath = Join-Path $exchange 'result.json'
$logPath = Join-Path $here 'launcher.log'

function Write-Log([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Write-Result([string]$id, [bool]$ok, [string]$message, $processId) {
    $result = [ordered]@{ id = $id; ok = $ok; message = $message; pid = $processId; at = (Get-Date).ToString('o') }
    New-Item -ItemType Directory -Force -Path $exchange | Out-Null
    ($result | ConvertTo-Json) | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Log ('{0} id={1}: {2}' -f ($(if ($ok) { 'ok' } else { 'failed' })), $id, $message)
}

# Closes processes by name: waits for them (after closing their main window when asked), then ends what is left by
# force. Returns how many it ended by force.
function Stop-Named([string[]]$names, [int]$waitSeconds, [bool]$closeWindows) {
    $running = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return 0 }
    if ($closeWindows) { foreach ($process in $running) { [void]$process.CloseMainWindow() } }
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    while ((Get-Date) -lt $deadline -and @(Get-Process -Name $names -ErrorAction SilentlyContinue).Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
    $left = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    foreach ($process in $left) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    Write-Log ('stopped {0} ({1} by force)' -f ($running.Name -join ', '), $left.Count)
    return $left.Count
}

$id = ''
try {
    $config = Get-Content -LiteralPath (Join-Path $here 'launcher.json') -Raw | ConvertFrom-Json
    $root = [IO.Path]::GetFullPath($config.artifactsRoot)
    if (-not (Test-Path -LiteralPath $requestPath)) { throw 'No request.json.' }
    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $requestPath -Force
    $id = [string]$request.id
    $build = [string]$request.build
    if ($build -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $build -match '\.\.') { throw "Not a build folder name: '$build'." }
    $folder = Join-Path $root $build
    $exe = Join-Path $folder 'PzTools.App.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "No PzTools.App.exe in $folder." }

    # Closing the app's window would only ask the player to confirm: "--exit" asks it to close as its Exit button
    # does, so work in progress stops and records how. An app too old to listen for that, or one that does not finish
    # in time, is ended by force, and then so are the workers it could not stop. An app that closed itself stopped
    # its workers; what it left running on purpose (the cleanup pass that waits for the game to close) stays.
    if (@(Get-Process -Name 'PzTools.App' -ErrorAction SilentlyContinue).Count -gt 0) {
        $asker = Start-Process -FilePath $exe -ArgumentList '--exit' -PassThru
        if (-not $asker.WaitForExit(30000)) { Stop-Process -Id $asker.Id -Force -ErrorAction SilentlyContinue }
        Write-Log 'asked the app to exit'
        if ((Stop-Named @('PzTools.App') 60 $false) -gt 0) {
            $workers = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'PzTools.*' })
            if ($workers.Count -gt 0) { [void](Stop-Named @($workers.Name | Sort-Object -Unique) 5 $false) }
        }
    }
    if ($request.stopGame -eq $true) { [void](Stop-Named @('ProjectZomboid64') 20 $true) }

    $process = Start-Process -FilePath $exe -WorkingDirectory $folder -PassThru
    Write-Result $id $true "Started $exe." $process.Id
}
catch {
    Write-Result $id $false $_.Exception.Message $null
    exit 1
}
