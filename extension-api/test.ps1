# Runs PZ Extension API's suites against a synthetic game (tests/game): "api" (the API as Lua mods see it) and "loader"
# (the install and the loader starting the game). Build first (build.ps1); the same -JdkPath.
#
#     ./test.ps1 [-JdkPath <jdk>] [-Suite api,loader] [-Release <folder>]
param([string] $JdkPath = $env:JAVA_HOME, [string[]] $Suite = @('api', 'loader'), [string] $Release = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($JdkPath) -or -not (Test-Path -LiteralPath (Join-Path $JdkPath 'bin/javac.exe'))) {
    throw 'A Java 25 JDK is required: pass -JdkPath or set JAVA_HOME.'
}
if ([string]::IsNullOrWhiteSpace($Release)) { $Release = Join-Path $root 'out/release' }
$java, $javac, $jar = (Join-Path $JdkPath 'bin/java.exe'), (Join-Path $JdkPath 'bin/javac.exe'), (Join-Path $JdkPath 'bin/jar.exe')
$work = Join-Path $root 'out/test'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

function Invoke-Tool([string] $failure, [string] $tool, [string[]] $arguments) {
    & $tool @arguments
    if ($LASTEXITCODE -ne 0) { throw $failure }
}
function Sources([string] $folder) { @(Get-ChildItem (Join-Path $root $folder) -Recurse -Filter '*.java' | ForEach-Object FullName) }

# The synthetic game: its classes, and its jar as the game's folder has it.
$game = Join-Path $work 'game'
Invoke-Tool 'The synthetic game did not compile' $javac (@('--release', '25', '-encoding', 'UTF-8', '-d', $game) + (Sources 'tests/game'))
$gameJar = Join-Path $work 'projectzomboid.jar'
Invoke-Tool 'The synthetic game jar failed' $jar (@('--create', '--file', $gameJar) + (Get-ChildItem $game -Directory | ForEach-Object { @('-C', $game, $_.Name) }))

$suites = [ordered]@{
    api = {
        $classes = Join-Path $work 'api'
        $classpath = @($classes, $game, (Join-Path $Release 'pzext-api.jar'), (Join-Path $Release 'pzext-boot.jar')) -join ';'
        Invoke-Tool 'The API tests did not compile' $javac (@('--release', '25', '-encoding', 'UTF-8', '-cp', $classpath, '-d', $classes) + (Sources 'tests/api'))
        # Puts the API's hooks into the synthetic game as its classes load, as the boot layer does.
        $agent = Join-Path $work 'test-agent.jar'
        Invoke-Tool 'The test agent failed' $jar @('--create', '--file', $agent, '--manifest', (Join-Path $root 'tests/api/TEST-AGENT.MF'), '-C', $classes, 'pzext/boot/TestAgent.class')
        Invoke-Tool 'The API tests failed' $java @("-javaagent:$agent", '-ea', "-Dpzext.test.repository=$root",
            "-Dpzext.test.apiJar=$(Join-Path $Release 'pzext-api.jar')", '-cp', $classpath, 'pzext.api.GameApiTest')
    }
    loader = {
        $classes = Join-Path $work 'loader'
        $classpath = @($classes, (Join-Path $Release 'pzext-install.jar'), (Join-Path $Release 'pzext-boot.jar')) -join ';'
        Invoke-Tool 'The loader test did not compile' $javac (@('--release', '25', '-encoding', 'UTF-8', '-cp', $classpath, '-d', $classes) + (Sources 'tests/loader'))
        # The shim's bytes do not depend on where or when it is built: the sources copied elsewhere and compiled again, with the
        # flags build.ps1 uses, give the very classes the installer carries (InstallTest pins their SHA-256).
        $again = Join-Path $work 'shim-again'
        Copy-Item (Join-Path $root 'src/shim') (Join-Path $again 'src') -Recurse
        Invoke-Tool 'The shim did not compile again' $javac (@('--release', '25', '-g:none', '-proc:none', '-encoding', 'UTF-8', '-d', (Join-Path $again 'classes')) +
            @(Get-ChildItem (Join-Path $again 'src') -Recurse -Filter '*.java' | ForEach-Object FullName))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $Release 'pzext-install.jar'))
        try {
            foreach ($entry in $archive.Entries | Where-Object { $_.FullName -like 'pzext/loader/*.class' }) {
                $stream = $entry.Open(); $bytes = [IO.MemoryStream]::new(); $stream.CopyTo($bytes); $stream.Dispose()
                $built = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes.ToArray()))
                $rebuilt = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes((Join-Path $again "classes/$($entry.FullName)"))))
                if ($built -ne $rebuilt) { throw "The shim class $($entry.FullName) is not the same when built again" }
            }
        } finally { $archive.Dispose() }
        Invoke-Tool 'The loader test failed' $java @('-ea', '-cp', $classpath, 'pzext.install.InstallTest', $gameJar, $Release, $java)
    }
}

$results = foreach ($name in $suites.Keys) {
    if ($name -notin $Suite) { continue }
    Write-Host "== $name"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { & $suites[$name] | Out-Host; $outcome = 'passed'; $detail = '' }
    catch { $outcome = 'FAILED'; $detail = $_.Exception.Message }
    [pscustomobject]@{ Suite = $name; Result = $outcome; Seconds = [int]$watch.Elapsed.TotalSeconds; Detail = $detail }
}
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if (@($results | Where-Object Result -eq 'FAILED').Count -gt 0) { throw 'Some suites failed' }
