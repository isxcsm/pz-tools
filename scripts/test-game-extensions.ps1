param(
    [Parameter(Mandatory=$true)][string] $JdkPath,
    [string] $Configuration = 'Release',
    [string] $BridgeDirectory,
    [string] $InstalledGameJar,
    [string] $InstalledVerificationLog,
    [string] $GameOverrides,
    # Builds the extension and the fixture modules and sets their variables, without running a test.
    [switch] $FixturesOnly
)
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($GameOverrides) -and [string]::IsNullOrWhiteSpace($InstalledGameJar)) {
    throw 'GameOverrides requires InstalledGameJar.'
}
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BridgeDirectory)) { $BridgeDirectory = Join-Path $root "artifacts/game-bridge/$Configuration" }
$java = Join-Path $JdkPath 'bin/java.exe'
$javac = Join-Path $JdkPath 'bin/javac.exe'
$jar = Join-Path $JdkPath 'bin/jar.exe'

# Everything is built first, so that the fixture modules the bridge tests use never wait on a test here.
& dotnet msbuild (Join-Path $root 'src/PzTools.GameExtensions.VehicleDrivetrain/PzTools.GameExtensions.VehicleDrivetrain.proj') /t:Build "-p:Configuration=$Configuration" "-p:JdkPath=$JdkPath" "-p:GameBridgeDirectory=$BridgeDirectory" /v:minimal
if ($LASTEXITCODE -ne 0) { throw 'Vehicle extension build failed.' }
$jars = Join-Path $BridgeDirectory 'extensions'
$runtimeJar = Join-Path $jars 'pztools-extension-runtime.jar'
$output = Join-Path $root 'artifacts/game-extension-tests'
New-Item -ItemType Directory -Force $output | Out-Null
$classpath = $runtimeJar + ';' + (Join-Path $jars 'pztools-vehicle-drivetrain.jar')
$sources = @(Get-ChildItem (Join-Path $root 'tests/game-extensions') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& $javac --release 25 -encoding UTF-8 -cp $classpath -d $output @sources
if ($LASTEXITCODE -ne 0) { throw 'Extension fixture compilation failed.' }

# A deliberately independent provider exercises transport ownership, not game persistence.
$fixtureClasses = Join-Path $output 'fixture-classes'
New-Item -ItemType Directory -Force $fixtureClasses | Out-Null
& $javac --release 25 -encoding UTF-8 -cp $runtimeJar -d $fixtureClasses (Join-Path $root 'tests/game-extensions-fixture/pztools/extensions/fixture/TestSaveProvider.java')
if ($LASTEXITCODE -ne 0) { throw 'Extension transport fixture compilation failed.' }
$env:PZTOOLS_EXTENSION_FIXTURE_JAR = Join-Path $output 'fixture-module.jar'
[IO.File]::WriteAllText((Join-Path $output 'fixture-module.mf'), "Manifest-Version: 1.0`nPzTools-Extension-Api: 3`n`n", [Text.UTF8Encoding]::new($false))
& $jar --create --manifest (Join-Path $output 'fixture-module.mf') --file $env:PZTOOLS_EXTENSION_FIXTURE_JAR -C $fixtureClasses pztools/extensions/fixture
if ($LASTEXITCODE -ne 0) { throw 'Extension transport fixture packaging failed.' }

$vehicleFixture = Join-Path $output 'vehicle-fixture'
New-Item -ItemType Directory -Force $vehicleFixture | Out-Null
$vehicleSources = @(Get-ChildItem (Join-Path $root 'tests/vehicle-drivetrain-fixture') -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName)
& $javac --release 25 -encoding UTF-8 -d $vehicleFixture @vehicleSources
if ($LASTEXITCODE -ne 0) { throw 'Vehicle adapter fixture compilation failed.' }

$continuousFixture = Join-Path $output 'continuous-fixture'
New-Item -ItemType Directory -Force $continuousFixture | Out-Null
& $javac --release 25 -encoding UTF-8 -cp $runtimeJar -d $continuousFixture (Join-Path $root 'tests/game-extensions-continuous-fixture/pztools/extensions/vehicle/VehicleDrivetrainProvider.java')
if ($LASTEXITCODE -ne 0) { throw 'Continuous extension transport fixture compilation failed.' }
$env:PZTOOLS_CONTINUOUS_FIXTURE_JAR = Join-Path $output 'continuous-fixture.jar'
& $jar --create --manifest (Join-Path $output 'fixture-module.mf') --file $env:PZTOOLS_CONTINUOUS_FIXTURE_JAR -C $continuousFixture pztools
if ($LASTEXITCODE -ne 0) { throw 'Continuous extension transport fixture packaging failed.' }

# A second synthetic continuous module beside one under the vehicle's catalogue name: the host then runs
# two modules through its real loading path. The second exists only here, with its own catalogue line.
$secondFixture = Join-Path $output 'second-fixture'
New-Item -ItemType Directory -Force $secondFixture | Out-Null
& $javac --release 25 -encoding UTF-8 -cp $runtimeJar -d $secondFixture (Join-Path $root 'tests/game-extensions-continuous-fixture/pztools/extensions/second/SecondModuleProvider.java')
if ($LASTEXITCODE -ne 0) { throw 'Second continuous fixture compilation failed.' }
& $jar --create --manifest (Join-Path $output 'fixture-module.mf') --file (Join-Path $output 'second-fixture.jar') -C $secondFixture pztools
if ($LASTEXITCODE -ne 0) { throw 'Second continuous fixture packaging failed.' }
$slots = Join-Path $output 'module-slots'
New-Item -ItemType Directory -Force $slots | Out-Null
Copy-Item $env:PZTOOLS_CONTINUOUS_FIXTURE_JAR (Join-Path $slots 'pztools-vehicle-drivetrain.jar') -Force
Copy-Item (Join-Path $output 'second-fixture.jar') (Join-Path $slots 'pztools-second-module.jar') -Force
$catalogue = [IO.File]::ReadAllText((Join-Path $root 'config/game-extensions/catalog.tsv')).TrimEnd() + "`n" + [IO.File]::ReadAllText((Join-Path $root 'tests/game-extensions/module-slots-second.tsv'))
[IO.File]::WriteAllText((Join-Path $slots 'catalog.tsv'), $catalogue, [Text.UTF8Encoding]::new($false))
if ($FixturesOnly) { return }

# Every test runs, whatever an earlier one did; the failures are named together at the end.
$failures = [Collections.Generic.List[string]]::new()
function Invoke-JavaTest([string] $name, [string[]] $arguments) {
    & $java -ea -cp ($output + ';' + $classpath) @arguments
    if ($LASTEXITCODE -ne 0) { $failures.Add($name) }
}
Invoke-JavaTest 'override archive validation' @('OverrideArchiveValidationTest', (Join-Path $output 'override-archive-validation'))
Invoke-JavaTest 'extension checkpoint behavior' @('CheckpointRuntimeTest')
Invoke-JavaTest 'shared extension version rules' @('VersionSupportTest', (Join-Path $root 'tests/game-extensions/version-support.tsv'), (Join-Path $root 'config/game-extensions/catalog.tsv'))
Invoke-JavaTest 'vehicle drivetrain model' @('pztools.extensions.vehicle.model.DrivetrainModelTest')
Invoke-JavaTest 'keyboard steering model' @('pztools.extensions.vehicle.model.SteeringModelTest')
Invoke-JavaTest 'key timeline' @('pztools.extensions.runtime.input.KeyTimelineTest')
Invoke-JavaTest 'vehicle adapter control preservation' @('pztools.extensions.vehicle.VehicleAdapterBehaviorTest', $vehicleFixture)
Invoke-JavaTest 'vehicle adapter compatibility' @('pztools.extensions.vehicle.VehicleCompatibilityTest', $vehicleFixture)
Invoke-JavaTest 'independent module slots' @('pztools.extensions.runtime.ModuleSlotsTest', $slots)

# Opt-in, read-only installed-class validation in a NEW verifier JVM. This is not an attach:
# no PID, jdk.attach, game entry point, vehicle instance, world or save is involved.
if (-not [string]::IsNullOrWhiteSpace($InstalledGameJar)) {
    $installedJar = Get-Item -LiteralPath $InstalledGameJar -ErrorAction Stop
    if ($installedJar.PSIsContainer -or $installedJar.Extension -ne '.jar') { throw 'InstalledGameJar must identify an existing JAR file.' }
    $verificationArguments = @($installedJar.FullName)
    $overrideArchive = $null
    if (-not [string]::IsNullOrWhiteSpace($GameOverrides)) {
        $overrideArchive = Get-Item -LiteralPath $GameOverrides -ErrorAction Stop
        if ($overrideArchive.PSIsContainer -or $overrideArchive.Extension -notin @('.jar', '.zip')) {
            throw 'GameOverrides must identify an existing JAR or ZIP file with class files at its root.'
        }
        $verificationArguments += $overrideArchive.FullName
    }
    if ([string]::IsNullOrWhiteSpace($InstalledVerificationLog)) {
        $InstalledVerificationLog = Join-Path $output 'installed-vehicle-verification.log'
    }
    $verificationLog = [IO.Path]::GetFullPath($InstalledVerificationLog)
    # A typo must not overwrite any installed game file or use the game directory for output.
    $installedDirectory = [IO.Path]::GetFullPath($installedJar.DirectoryName) + [IO.Path]::DirectorySeparatorChar
    if ($verificationLog.StartsWith($installedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstalledVerificationLog must be outside the installed game directory.'
    }
    if ($null -ne $overrideArchive -and $verificationLog.Equals($overrideArchive.FullName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstalledVerificationLog must not overwrite GameOverrides.'
    }
    New-Item -ItemType Directory -Force ([IO.Path]::GetDirectoryName($verificationLog)) | Out-Null
    $verificationAgent = Join-Path $output 'vehicle-validation-agent.jar'
    & $jar --create --manifest (Join-Path $root 'tests/game-extensions/vehicle-validation-agent.mf') --file $verificationAgent -C $output PrivateValidationAgent.class
    if ($LASTEXITCODE -ne 0) { throw 'Offline vehicle validation agent packaging failed.' }
    Write-Host "Read-only installed vehicle verification (separate JVM): $($installedJar.FullName)"
    if ($null -ne $overrideArchive) { Write-Host "Class overrides take precedence over the installed JAR: $($overrideArchive.FullName)" }
    & $java -ea "-javaagent:$verificationAgent" -cp ($output + ';' + $classpath) VerifyInstalledVehicleBytecode @verificationArguments 2>&1 | Tee-Object -FilePath $verificationLog
    $verificationExit = $LASTEXITCODE
    Write-Host "Installed vehicle verification log: $verificationLog"
    if ($verificationExit -ne 0) { $failures.Add("installed vehicle verification (see $verificationLog)") }
} elseif (-not [string]::IsNullOrWhiteSpace($InstalledVerificationLog)) {
    throw 'InstalledVerificationLog requires InstalledGameJar.'
}
if ($failures.Count -gt 0) { throw "Extension tests failed: $($failures -join '; ')" }
