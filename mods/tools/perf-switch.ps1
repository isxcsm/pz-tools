<#
Switches the game's mods and the PZ Extension API between the two builds of the R3 performance comparison (E2E.md 10.1):
c0, the last dev commit before the world-query work (a4692230, the worktree C:\git\pz-workspace\wt-c0), and c1, dev now
(the main checkout, C:\git\pz-workspace\pz-tools).

    powershell -NoProfile -ExecutionPolicy Bypass -File mods\tools\perf-switch.ps1 -To c0            what it would do
    powershell -NoProfile -ExecutionPolicy Bypass -File mods\tools\perf-switch.ps1 -To c0 -Apply     does it
    powershell -NoProfile -ExecutionPolicy Bypass -File mods\tools\perf-switch.ps1 -To c1 -Apply
    powershell -NoProfile -ExecutionPolicy Bypass -File mods\tools\perf-switch.ps1 -To c1 -Apply -Install   and installs the API

What it changes, with the game closed:
 - the six junctions in Zomboid\mods (BuildingUtilities, BuildingUtilitiesDev, OperationAcorn, OperationAcornDev,
   PZUIKit, PZExtDev) are pointed into the build's checkout (only a junction or a link is replaced; a real folder stops it);
 - the API: of the API's two builds only pzext-api.jar differs (nothing of the boot layer, the loader or the installer
   changed between c0 and c1). The main checkout's extension-api\out\release\pzext-api.jar is what a game started by
   pzdev runs (PZEXT_DEV_RELOAD) and what request-api-install.ps1 installs, so it is replaced by the build's jar (c1's kept
   beside it as pzext-api.c1.jar; c0's jar comes from wt-c0\extension-api\out\release, built there by build.ps1).
 - the junctions Zomboid\Lua\oa and bu (the in-game checks) stay on the main checkout, so perf_r3.lua must be in it
   (merged into dev) whichever build is switched to.
-Install also runs scripts\dev\request-api-install.ps1 (the elevated task installs the jar for a game not started by
pzdev; a game pzdev starts needs no install).
#>
param(
    [Parameter(Mandatory)][ValidateSet('c0', 'c1')][string]$To,
    [switch]$Apply,
    [switch]$Install,
    [string]$C0 = 'C:\git\pz-workspace\wt-c0',
    [string]$C1 = 'C:\git\pz-workspace\pz-tools'
)
$ErrorActionPreference = 'Stop'
$root = if ($To -eq 'c0') { $C0 } else { $C1 }
$mods = Join-Path $env:USERPROFILE 'Zomboid\mods'
$links = [ordered]@{
    BuildingUtilities    = 'mods\building-utilities\BuildingUtilities'
    BuildingUtilitiesDev = 'mods\building-utilities\BuildingUtilitiesDev'
    OperationAcorn       = 'mods\operation-acorn\OperationAcorn'
    OperationAcornDev    = 'mods\operation-acorn\OperationAcornDev'
    PZUIKit              = 'mods\pz-ui-kit\PZUIKit'
    PZExtDev             = 'extension-api\dev\PZExtDev'
}
function Say([string]$text) { Write-Host ($(if ($Apply) { '' } else { '[dry run] ' }) + $text) }

if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "No checkout at $root." }
if (Get-Process -Name 'ProjectZomboid64' -ErrorAction SilentlyContinue) { throw 'The game is running: close it first (pzdev quit).' }
$head = & 'C:\Program Files\Git\cmd\git.exe' -C $root log -1 --format='%h %s'
Say "target $To = $root ($head)"
if ($To -eq 'c0' -and -not $head.StartsWith('a4692230')) { throw "wt-c0 is not at a4692230: $head" }

# 1. the mods
foreach ($name in $links.Keys) {
    $link = Join-Path $mods $name
    $target = Join-Path $root $links[$name]
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "No folder $target." }
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    $now = if ($item) { ($item.Target | Select-Object -First 1) } else { $null }
    if ($item -and -not $item.LinkType) { throw "$link is a real folder, not a junction: not touched." }
    if ($now -and ([IO.Path]::GetFullPath($now).TrimEnd('\') -ieq [IO.Path]::GetFullPath($target).TrimEnd('\'))) {
        Say "$name already -> $target"
        continue
    }
    Say "$name : $now -> $target"
    if ($Apply) {
        if ($item) { [IO.Directory]::Delete($link) }
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
}

# 2. the API's jar
$release = Join-Path $C1 'extension-api\out\release'
$jar = Join-Path $release 'pzext-api.jar'
$keep = Join-Path $release 'pzext-api.c1.jar'
$c0jar = Join-Path $C0 'extension-api\out\release\pzext-api.jar'
function Hash([string]$path) { if (Test-Path -LiteralPath $path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.Substring(0, 12).ToLower() } else { 'none' } }
if ($To -eq 'c0') {
    if (-not (Test-Path -LiteralPath $c0jar)) { throw "No ${c0jar}: build it (extension-api\build.ps1 -JdkPath <jdk>) in $C0." }
    if ((Hash $jar) -eq (Hash $c0jar)) {
        Say "API jar already c0's ($(Hash $jar))"
    } else {
        Say "API jar $(Hash $jar) -> c0's $(Hash $c0jar) (c1's kept as pzext-api.c1.jar)"
        if ($Apply) {
            if (-not (Test-Path -LiteralPath $keep)) { Copy-Item -LiteralPath $jar -Destination $keep }
            Copy-Item -LiteralPath $c0jar -Destination $jar -Force
        }
    }
} else {
    if (-not (Test-Path -LiteralPath $keep)) {
        Say "API jar: no pzext-api.c1.jar kept; if the jar here is c0's (check with the hash $(Hash $jar)), rebuild c1's: extension-api\build.ps1"
    } elseif ((Hash $jar) -eq (Hash $keep)) {
        Say "API jar already c1's ($(Hash $jar))"
    } else {
        Say "API jar $(Hash $jar) -> c1's $(Hash $keep)"
        if ($Apply) { Copy-Item -LiteralPath $keep -Destination $jar -Force }
    }
}
if ($Install) {
    Say 'installing the API (request-api-install.ps1: the elevated task installs out\release)'
    if ($Apply) { & (Join-Path $C1 'scripts\dev\request-api-install.ps1') }
}
Say 'done. Start the game with pzdev launch --save BU_Spawn_E2E; the harness prints build= and the mods folder it runs on.'
