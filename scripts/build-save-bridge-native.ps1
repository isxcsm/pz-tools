param([Parameter(Mandatory=$true)][string] $JdkPath, [Parameter(Mandatory=$true)][string] $Output)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio C++ tools are required for the Windows attach bootstrap.' }
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vsRoot)) { throw 'Visual Studio x64 C++ tools are not installed.' }
& (Join-Path $PSScriptRoot 'build-save-bridge-native.cmd') (Join-Path $vsRoot 'VC/Auxiliary/Build/vcvars64.bat') $JdkPath `
    (Join-Path $repositoryRoot 'src/PzTools.SaveBridge.Native/bootstrap.cpp') $Output
if ($LASTEXITCODE -ne 0) { throw 'Save bridge native bootstrap compilation failed' }
