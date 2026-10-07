<#
Registers (or with -Unregister removes) the scheduled task that runs elevated-launcher.ps1 with administrator
rights, for development on this computer. Run it once from an administrator PowerShell, as the user who develops.

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\register-elevated-launcher.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\register-elevated-launcher.ps1 -Unregister

It copies the launcher to %ProgramData%\PzToolsDev, which only administrators (and SYSTEM) may change, with
launcher.json naming the artifacts root, and registers the task \PzToolsDev\ElevatedLaunch: run as this user, only
while they are signed in (so the app's window shows on their desktop), with the highest privileges, started on
demand only (request-elevated-launch.ps1 starts it with schtasks /run).

What it allows: anything running as this user can start an app build from the artifacts root with administrator
rights and no UAC prompt. The artifacts root is the user's own folder, so a program running as the user could put an
executable there and start it that way. Remove the task when it is not needed.
#>
param(
    [string]$ArtifactsRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'artifacts'),
    [switch]$Unregister
)
$ErrorActionPreference = 'Stop'
$taskPath = '\PzToolsDev\'
$taskName = 'ElevatedLaunch'
$installDir = Join-Path $env:ProgramData 'PzToolsDev'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator PowerShell.'
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    Write-Host 'Removed the task and its folder.'
    return
}

$root = [IO.Path]::GetFullPath($ArtifactsRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "No artifacts folder at $root." }

# The folder: administrators and SYSTEM change it, users only read it.
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$none = [Security.AccessControl.PropagationFlags]::None
foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
    $account = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount])
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($account, 'FullControl', $inherit, $none, 'Allow')))
}
$users = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([Security.Principal.NTAccount])
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', $inherit, $none, 'Allow')))
Set-Acl -LiteralPath $installDir -AclObject $acl

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'elevated-launcher.ps1') -Destination (Join-Path $installDir 'launcher.ps1') -Force
(@{ artifactsRoot = $root } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $installDir 'launcher.json') -Encoding UTF8

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $installDir 'launcher.ps1'))
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Principal $taskPrincipal `
    -Settings $settings -Description 'PZ Tools development: restart the app from a build folder with administrator rights.' `
    -Force | Out-Null
Write-Host "Registered $taskPath$taskName for $user; builds from $root."
