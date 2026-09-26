param([Parameter(Mandatory=$true)][string] $JdkPath, [string] $Configuration = 'Release', [string] $BridgeDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BridgeDirectory)) { $BridgeDirectory = Join-Path $root "artifacts/save-bridge/$Configuration" }
& dotnet msbuild (Join-Path $root 'src/PzTools.GameExtensions.SeamlessSave/PzTools.GameExtensions.SeamlessSave.proj') /t:Build "-p:Configuration=$Configuration" "-p:JdkPath=$JdkPath" "-p:SaveBridgeDirectory=$BridgeDirectory" /v:minimal
if ($LASTEXITCODE -ne 0) { throw 'Extension build failed.' }
$jars = Join-Path $BridgeDirectory 'extensions'
$output = Join-Path $root 'artifacts/game-extension-tests'
New-Item -ItemType Directory -Force $output | Out-Null
$classpath = (Join-Path $jars 'pztools-extension-runtime.jar') + ';' + (Join-Path $jars 'pztools-seamless-save.jar')
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp $classpath -d $output (Join-Path $root 'tests/game-extensions/CheckpointRuntimeTest.java')
if ($LASTEXITCODE -ne 0) { throw 'Extension fixture compilation failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) CheckpointRuntimeTest
if ($LASTEXITCODE -ne 0) { throw 'Extension checkpoint behavior test failed.' }
