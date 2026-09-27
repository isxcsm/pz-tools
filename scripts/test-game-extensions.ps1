param(
    [Parameter(Mandatory=$true)][string] $JdkPath,
    [string] $Configuration = 'Release',
    [string] $BridgeDirectory,
    [string] $InstalledGameJar,
    [string] $InstalledVerificationLog
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BridgeDirectory)) { $BridgeDirectory = Join-Path $root "artifacts/save-bridge/$Configuration" }
& dotnet msbuild (Join-Path $root 'src/PzTools.GameExtensions.VehicleDrivetrain/PzTools.GameExtensions.VehicleDrivetrain.proj') /t:Build "-p:Configuration=$Configuration" "-p:JdkPath=$JdkPath" "-p:SaveBridgeDirectory=$BridgeDirectory" /v:minimal
if ($LASTEXITCODE -ne 0) { throw 'Vehicle extension build failed.' }
$jars = Join-Path $BridgeDirectory 'extensions'
$output = Join-Path $root 'artifacts/game-extension-tests'
New-Item -ItemType Directory -Force $output | Out-Null
$classpath = (Join-Path $jars 'pztools-extension-runtime.jar') + ';' + (Join-Path $jars 'pztools-vehicle-drivetrain.jar')
$sources = @(Get-ChildItem (Join-Path $root 'tests/game-extensions') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp $classpath -d $output @sources
if ($LASTEXITCODE -ne 0) { throw 'Extension fixture compilation failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) CheckpointRuntimeTest
if ($LASTEXITCODE -ne 0) { throw 'Extension checkpoint behavior test failed.' }

# A deliberately independent provider exercises transport ownership, not game persistence.
$fixtureClasses = Join-Path $output 'fixture-classes'
$fixtureSource = Join-Path $root 'tests/game-extensions-fixture/pztools/extensions/fixture/TestSaveProvider.java'
New-Item -ItemType Directory -Force $fixtureClasses | Out-Null
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp (Join-Path $jars 'pztools-extension-runtime.jar') -d $fixtureClasses $fixtureSource
if ($LASTEXITCODE -ne 0) { throw 'Extension transport fixture compilation failed.' }
$env:PZTOOLS_EXTENSION_FIXTURE_JAR = Join-Path $output 'fixture-module.jar'
[IO.File]::WriteAllText((Join-Path $output 'fixture-module.mf'), "Manifest-Version: 1.0`nPzTools-Extension-Api: 3`n`n", [Text.UTF8Encoding]::new($false))
& (Join-Path $JdkPath 'bin/jar.exe') --create --manifest (Join-Path $output 'fixture-module.mf') --file $env:PZTOOLS_EXTENSION_FIXTURE_JAR -C $fixtureClasses pztools/extensions/fixture
if ($LASTEXITCODE -ne 0) { throw 'Extension transport fixture packaging failed.' }

& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) VersionSupportTest (Join-Path $root 'tests/game-extensions/version-support.tsv') (Join-Path $root 'config/game-extensions/catalog.tsv')
if ($LASTEXITCODE -ne 0) { throw 'Shared extension version rules failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) pztools.extensions.vehicle.model.DrivetrainModelTest
if ($LASTEXITCODE -ne 0) { throw 'Vehicle drivetrain model behavior failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) pztools.extensions.vehicle.model.SteeringModelTest
if ($LASTEXITCODE -ne 0) { throw 'Keyboard steering model behavior failed.' }

$vehicleFixture = Join-Path $output 'vehicle-fixture'
New-Item -ItemType Directory -Force $vehicleFixture | Out-Null
$vehicleSources = @(Get-ChildItem (Join-Path $root 'tests/vehicle-drivetrain-fixture') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -d $vehicleFixture @vehicleSources
if ($LASTEXITCODE -ne 0) { throw 'Vehicle adapter fixture compilation failed.' }
& (Join-Path $JdkPath 'bin/java.exe') -ea -cp ($output + ';' + $classpath) pztools.extensions.vehicle.VehicleAdapterBehaviorTest $vehicleFixture
if ($LASTEXITCODE -ne 0) { throw 'Vehicle adapter control preservation failed.' }

$continuousFixture = Join-Path $output 'continuous-fixture'
New-Item -ItemType Directory -Force $continuousFixture | Out-Null
$continuousSource = Join-Path $root 'tests/game-extensions-continuous-fixture/pztools/extensions/vehicle/VehicleDrivetrainProvider.java'
& (Join-Path $JdkPath 'bin/javac.exe') --release 25 -encoding UTF-8 -cp (Join-Path $jars 'pztools-extension-runtime.jar') -d $continuousFixture $continuousSource
if ($LASTEXITCODE -ne 0) { throw 'Continuous extension transport fixture compilation failed.' }
$env:PZTOOLS_CONTINUOUS_FIXTURE_JAR = Join-Path $output 'continuous-fixture.jar'
& (Join-Path $JdkPath 'bin/jar.exe') --create --manifest (Join-Path $output 'fixture-module.mf') --file $env:PZTOOLS_CONTINUOUS_FIXTURE_JAR -C $continuousFixture pztools
if ($LASTEXITCODE -ne 0) { throw 'Continuous extension transport fixture packaging failed.' }

# Opt-in, read-only installed-class validation in a NEW verifier JVM. This is not an attach:
# no PID, jdk.attach, game entry point, vehicle instance, world or save is involved.
if (-not [string]::IsNullOrWhiteSpace($InstalledGameJar)) {
    $installedJar = Get-Item -LiteralPath $InstalledGameJar -ErrorAction Stop
    if ($installedJar.PSIsContainer -or $installedJar.Extension -ne '.jar') { throw 'InstalledGameJar must identify an existing JAR file.' }
    if ([string]::IsNullOrWhiteSpace($InstalledVerificationLog)) {
        $InstalledVerificationLog = Join-Path $output 'installed-vehicle-verification.log'
    }
    $verificationLog = [IO.Path]::GetFullPath($InstalledVerificationLog)
    # A typo must not overwrite any installed game file or use the game directory for output.
    $installedDirectory = [IO.Path]::GetFullPath($installedJar.DirectoryName) + [IO.Path]::DirectorySeparatorChar
    if ($verificationLog.StartsWith($installedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstalledVerificationLog must be outside the installed game directory.'
    }
    New-Item -ItemType Directory -Force ([IO.Path]::GetDirectoryName($verificationLog)) | Out-Null
    $verificationAgent = Join-Path $output 'vehicle-validation-agent.jar'
    & (Join-Path $JdkPath 'bin/jar.exe') --create --manifest (Join-Path $root 'tests/game-extensions/vehicle-validation-agent.mf') --file $verificationAgent -C $output PrivateValidationAgent.class
    if ($LASTEXITCODE -ne 0) { throw 'Offline vehicle validation agent packaging failed.' }
    Write-Host "Read-only installed vehicle verification (separate JVM): $($installedJar.FullName)"
    & (Join-Path $JdkPath 'bin/java.exe') -ea "-javaagent:$verificationAgent" -cp ($output + ';' + $classpath) VerifyInstalledVehicleBytecode $installedJar.FullName 2>&1 | Tee-Object -FilePath $verificationLog
    $verificationExit = $LASTEXITCODE
    Write-Host "Installed vehicle verification log: $verificationLog"
    if ($verificationExit -ne 0) { throw "Offline installed vehicle verification failed; see $verificationLog" }
} elseif (-not [string]::IsNullOrWhiteSpace($InstalledVerificationLog)) {
    throw 'InstalledVerificationLog requires InstalledGameJar.'
}
