#Requires -Version 7.2
# Builds a release from the committed source in one step: publish the app, test the published
# folder, then package it as the ZIP and SHA-256 file attached to a GitHub release.
# The version comes from <Version> in Directory.Build.props; the output goes to
# artifacts/release/v<version>/, which must not exist yet.
param(
    [Parameter(Mandatory)][string] $JdkPath,
    [string] $OutputRoot = 'artifacts/release',
    # Only for trying the script out: a release is built from committed source.
    [switch] $AllowUncommitted
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

[xml] $props = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Directory.Build.props') -Raw
$version = @($props.Project.PropertyGroup | ForEach-Object { $_.Version } | Where-Object { $_ })[0]
if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { throw "Directory.Build.props has no usable <Version>: '$version'" }

$git = Get-Command git -ErrorAction SilentlyContinue
$commit = 'unknown'
if ($git) {
    $commit = (& git -C $repositoryRoot rev-parse --short HEAD).Trim()
    $changes = & git -C $repositoryRoot status --porcelain --untracked-files=no
    if ($changes -and -not $AllowUncommitted) {
        throw "Uncommitted changes would not match commit $commit. Commit them first (or pass -AllowUncommitted to try the script)."
    }
} else { Write-Warning 'git was not found; the source state is not checked.' }

$relative = Join-Path $OutputRoot "v$version"
$releaseDirectory = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relative))
if (Test-Path -LiteralPath $releaseDirectory) {
    throw "$releaseDirectory already exists. Move it away, or raise <Version> in Directory.Build.props."
}
New-Item -ItemType Directory -Path $releaseDirectory | Out-Null
$app = Join-Path $releaseDirectory 'PzTools'

Write-Host "== Publishing PZ Tools $version ($commit)"
# A fresh Java build folder, so the payload reuses nothing from earlier development builds.
& (Join-Path $PSScriptRoot 'publish-app.ps1') -Configuration Release -JdkPath $JdkPath -Output (Join-Path $relative 'PzTools') `
    -GameBridgeOutput (Join-Path $relative 'game-bridge-build')
if ($LASTEXITCODE -ne 0) { throw 'Publishing failed.' }
$published = (Get-Item -LiteralPath (Join-Path $app 'PzTools.App.exe')).VersionInfo.ProductVersion
if ($published.Split('+')[0] -ne $version) { throw "The published app says $published, not $version." }

Write-Host '== Testing the published folder'
$env:PZTOOLS_DISTRIBUTION_DIR = $app
$env:PZTOOLS_TOOLS_DIR = $app
try {
    dotnet test (Join-Path $repositoryRoot 'tests/PzTools.Backup.Tests') -c Release -p:JdkPath="$JdkPath" `
        --filter 'FullyQualifiedName~PublishedDistributionTests|FullyQualifiedName~PublishedWorker' --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'The published folder failed its tests.' }
}
finally {
    Remove-Item Env:PZTOOLS_DISTRIBUTION_DIR, Env:PZTOOLS_TOOLS_DIR -ErrorAction SilentlyContinue
}

Write-Host '== Packaging'
$archive = Join-Path $releaseDirectory "PzTools-v$version-win-x64.zip"
# The ZIP's folder is named for the version: a new release extracts beside the old one, never over it.
& (Join-Path $PSScriptRoot 'package-release.ps1') -PublishDirectory $app -OutputArchive $archive -RootFolder "PzTools-v$version"

Write-Host ''
Write-Host "PZ Tools $version from commit $commit"
Write-Host "  Attach to the release: $archive"
Write-Host "                         $archive.sha256"
