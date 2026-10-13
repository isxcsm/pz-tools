# Builds PZ Extension API into a release folder (out\release by default): the installer, the boot layer, the API, the
# loader's native library and the embedded fonts. Needs a Java 25 JDK (-JdkPath, or JAVA_HOME) and, for the native
# library, Visual Studio's x64 C++ tools.
#
#     ./build.ps1 [-JdkPath <jdk>] [-Output <folder>]
param([string] $JdkPath = $env:JAVA_HOME, [string] $Output = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($JdkPath) -or -not (Test-Path -LiteralPath (Join-Path $JdkPath 'bin/javac.exe'))) {
    throw 'A Java 25 JDK is required: pass -JdkPath or set JAVA_HOME.'
}
if ([string]::IsNullOrWhiteSpace($Output)) { $Output = Join-Path $root 'out/release' }
$work = Join-Path $root 'out/work'
$javac, $jar = (Join-Path $JdkPath 'bin/javac.exe'), (Join-Path $JdkPath 'bin/jar.exe')

function Invoke-Tool([string] $failure, [string] $tool, [string[]] $arguments) {
    & $tool @arguments
    if ($LASTEXITCODE -ne 0) { throw $failure }
}
function Sources([string] $folder) { @(Get-ChildItem (Join-Path $root $folder) -Recurse -Filter '*.java' | ForEach-Object FullName) }

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
foreach ($folder in 'boot', 'api', 'loader', 'install', 'native') { New-Item -ItemType Directory -Force (Join-Path $work $folder) | Out-Null }
New-Item -ItemType Directory -Force $Output | Out-Null

# The boot layer: loaded once by the loader, never replaced.
Invoke-Tool 'The boot layer did not compile' $javac (@('--release', '25', '-encoding', 'UTF-8', '-d', (Join-Path $work 'boot')) + (Sources 'src/boot'))
# The API: its own jar, which a newer one replaces in a running game.
Invoke-Tool 'The API did not compile' $javac (@('--release', '25', '-encoding', 'UTF-8', '-cp', (Join-Path $work 'boot'), '-d', (Join-Path $work 'api')) + (Sources 'src/api'))
# The loader's classes go into the game's folder; the installer carries them.
Invoke-Tool 'The loader did not compile' $javac (@('--release', '25', '-encoding', 'UTF-8', '-d', (Join-Path $work 'install')) + (Sources 'src/loader') + (Sources 'src/install'))

$manifests = Join-Path $work 'manifests'
New-Item -ItemType Directory -Force $manifests | Out-Null
Set-Content -Encoding ascii (Join-Path $manifests 'boot.mf') "Manifest-Version: 1.0`r`nAgent-Class: pzext.boot.Boot`r`nCan-Retransform-Classes: true`r`n"
Set-Content -Encoding ascii (Join-Path $manifests 'api.mf') "Manifest-Version: 1.0`r`nPZExt-Boot-Api: 1`r`n"
Set-Content -Encoding ascii (Join-Path $manifests 'install.mf') "Manifest-Version: 1.0`r`nMain-Class: pzext.install.Install`r`n"
# Reproducible bytes: the same sources give the same jars, so an install of the same build is the same version folder.
$date = '--date=2020-01-01T00:00:00Z'
Invoke-Tool 'The boot jar failed' $jar @('--create', $date, '--file', (Join-Path $Output 'pzext-boot.jar'), '--manifest', (Join-Path $manifests 'boot.mf'), '-C', (Join-Path $work 'boot'), 'pzext')
Invoke-Tool 'The API jar failed' $jar @('--create', $date, '--file', (Join-Path $Output 'pzext-api.jar'), '--manifest', (Join-Path $manifests 'api.mf'), '-C', (Join-Path $work 'api'), 'pzext')
Invoke-Tool 'The installer jar failed' $jar @('--create', $date, '--file', (Join-Path $Output 'pzext-install.jar'), '--manifest', (Join-Path $manifests 'install.mf'), '-C', (Join-Path $work 'install'), 'pzext')

# The loader's native library.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio's C++ tools are required for the loader's native library." }
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vs)) { throw "Visual Studio's x64 C++ tools are not installed." }
& (Join-Path $root 'build/native.cmd') (Join-Path $vs 'VC/Auxiliary/Build/vcvars64.bat') $JdkPath (Join-Path $root 'src/native/loader.cpp') (Join-Path $work 'native')
if ($LASTEXITCODE -ne 0) { throw 'The native library did not compile' }
Copy-Item (Join-Path $work 'native/pzext-loader.dll') $Output -Force

# The embedded fonts and their license.
New-Item -ItemType Directory -Force (Join-Path $Output 'fonts') | Out-Null
Copy-Item (Join-Path $root 'fonts/*') (Join-Path $Output 'fonts') -Force
Copy-Item (Join-Path $root 'LICENSE') $Output -Force
Write-Host "Built $Output"
