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
$sources = @(Get-ChildItem (Join-Path $root 'tests/game-extensions') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp $classpath -d $output @sources
if ($LASTEXITCODE -ne 0) { throw 'Extension fixture compilation failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) CheckpointRuntimeTest
if ($LASTEXITCODE -ne 0) { throw 'Extension checkpoint behavior test failed.' }

& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) pztools.extensions.seamless.b4220.SaveAdapterBehaviorTest
if ($LASTEXITCODE -ne 0) { throw 'Save adapter barrier behavior test failed.' }

# A deliberately independent provider exercises transport ownership, not game persistence.
$fixtureClasses = Join-Path $output 'fixture-classes'
$fixtureSource = Join-Path $root 'tests/game-extensions-fixture/pztools/extensions/seamless/SeamlessSaveProvider.java'
New-Item -ItemType Directory -Force $fixtureClasses | Out-Null
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp (Join-Path $jars 'pztools-extension-runtime.jar') -d $fixtureClasses $fixtureSource
if ($LASTEXITCODE -ne 0) { throw 'Extension transport fixture compilation failed.' }
$env:PZTOOLS_EXTENSION_FIXTURE_JAR = Join-Path $output 'fixture-module.jar'
& (Join-Path $JdkPath 'bin/jar.exe') --create --file $env:PZTOOLS_EXTENSION_FIXTURE_JAR -C $fixtureClasses pztools
if ($LASTEXITCODE -ne 0) { throw 'Extension transport fixture packaging failed.' }

& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) SaveBytecodeExecutionTest
if ($LASTEXITCODE -ne 0) { throw 'Save bytecode behavior test failed.' }

$chunkFixture = Join-Path $output 'chunk-fixture'
New-Item -ItemType Directory -Force $chunkFixture | Out-Null
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -d $chunkFixture (Join-Path $root 'tests/game-extensions-chunk-fixture/ChunkIoTemplate.java')
if ($LASTEXITCODE -ne 0) { throw 'Chunk I/O fixture compilation failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) pztools.extensions.seamless.b4220.DeferredChunkWriteTest $chunkFixture
if ($LASTEXITCODE -ne 0) { throw 'Deferred chunk I/O behavior test failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) VersionSupportTest (Join-Path $root 'tests/game-extensions/version-support.tsv')
if ($LASTEXITCODE -ne 0) { throw 'Shared extension version rules failed.' }