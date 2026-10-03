#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string] $PublishDirectory,
    [Parameter(Mandatory)][string] $OutputArchive,
    # The ZIP's one top-level folder. A release names it for its version, so extracting a new release makes a new
    # folder rather than overwriting the one in use.
    [string] $RootFolder = 'PzTools'
)
$ErrorActionPreference = 'Stop'
if ($RootFolder -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') { throw 'RootFolder must be a plain folder name.' }

function Assert-NoReparse([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links are not allowed: $($item.FullName)" }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

function Get-Snapshot([string] $Root) {
    Assert-NoReparse $Root
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            Assert-NoReparse $item.FullName
            $relative = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
            if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('../')) {
                throw "Path escapes the publish directory: $relative"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            if (-not $names.Add($relative)) { throw "Duplicate Windows path: $relative" }
            $files.Add($relative, [pscustomobject]@{
                Path = $item.FullName; Length = $item.Length; Modified = $item.LastWriteTimeUtc.Ticks
                Stream = $null; Hash = $null
            })
        }
    }
    return ,$files
}

$source = Get-Item -LiteralPath $PublishDirectory -Force
if ($source -isnot [IO.DirectoryInfo]) { throw 'PublishDirectory must be a filesystem directory.' }
$sourceRoot = $source.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($source.FullName -eq [IO.Path]::GetPathRoot($source.FullName)) { throw 'A filesystem root cannot be packaged.' }
$archivePath = [IO.Path]::GetFullPath($OutputArchive)
if ([IO.Path]::GetExtension($archivePath) -ine '.zip') { throw 'OutputArchive must end in .zip.' }
if ($archivePath.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The archive must be outside the publish directory.'
}
$parent = [IO.Path]::GetDirectoryName($archivePath)
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'The archive parent directory must already exist.' }
Assert-NoReparse $parent
$checksumPath = $archivePath + '.sha256'
$partialArchive = $archivePath + '.partial'
$partialChecksum = $checksumPath + '.partial'
foreach ($path in @($archivePath, $checksumPath, $partialArchive, $partialChecksum)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to replace an existing path: $path" }
}
$files = Get-Snapshot $sourceRoot
if (Test-Path -LiteralPath (Join-Path $sourceRoot 'START-HERE.txt')) { throw 'START-HERE.txt is reserved for the packaged release guide.' }
$template = Get-Item -LiteralPath (Join-Path $PSScriptRoot '../build/START-HERE.txt')
Assert-NoReparse $template.FullName
$files.Add('START-HERE.txt', [pscustomobject]@{
    Path = $template.FullName; Length = $template.Length; Modified = $template.LastWriteTimeUtc.Ticks
    Stream = $null; Hash = $null
})
$zipStream = $null
$ownsArchive = $false
$ownsChecksum = $false
try {
    # Hold read-only, non-write/non-delete-sharing handles until the package is verified.
    foreach ($file in $files.Values) {
        Assert-NoReparse $file.Path
        $file.Stream = [IO.File]::Open($file.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($file.Stream.Length -ne $file.Length -or [IO.File]::GetLastWriteTimeUtc($file.Path).Ticks -ne $file.Modified) {
            throw "Source changed before reading: $($file.Path)"
        }
    }
    $zipStream = [IO.File]::Open($partialArchive, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $ownsArchive = $true
    $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($name in $files.Keys) {
            $file = $files[$name]
            $entry = $zip.CreateEntry("$RootFolder/" + $name, [IO.Compression.CompressionLevel]::SmallestSize)
            $entry.LastWriteTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $destination = $entry.Open()
            try { $file.Stream.CopyTo($destination) } finally { $destination.Dispose() }
            $file.Stream.Position = 0
            $file.Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($file.Stream))
        }
    }
    finally { $zip.Dispose() }
    $zipStream.Position = 0
    $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        if ($zip.Entries.Count -ne $files.Count) { throw 'ZIP file count mismatch.' }
        $index = 0
        foreach ($name in $files.Keys) {
            $entry = $zip.Entries[$index++]
            if ($entry.FullName -cne ("$RootFolder/" + $name) -or $entry.Length -ne $files[$name].Length) { throw "ZIP entry mismatch: $name" }
            $entryStream = $entry.Open()
            try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entryStream)) }
            finally { $entryStream.Dispose() }
            if ($hash -cne $files[$name].Hash) { throw "ZIP content mismatch: $name" }
        }
    }
    finally { $zip.Dispose() }
    $current = Get-Snapshot $sourceRoot
    $sourceNames = @($files.Keys | Where-Object { $_ -cne 'START-HERE.txt' })
    if (($sourceNames -join "`n") -cne (@($current.Keys) -join "`n")) { throw 'Source file list changed during packaging.' }
    foreach ($name in $files.Keys) {
        if ([IO.File]::GetLastWriteTimeUtc($files[$name].Path).Ticks -ne $files[$name].Modified) { throw "Source changed during packaging: $name" }
    }
    $zipStream.Position = 0
    $archiveHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($zipStream)).ToLowerInvariant()
    $zipStream.Dispose(); $zipStream = $null
    $checksum = [IO.File]::Open($partialChecksum, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $ownsChecksum = $true
    try { $checksum.Write([Text.Encoding]::UTF8.GetBytes("$archiveHash  $([IO.Path]::GetFileName($archivePath))`n")) }
    finally { $checksum.Dispose() }
    Assert-NoReparse $parent
    [IO.File]::Move($partialArchive, $archivePath)
    $ownsArchive = $false
    [IO.File]::Move($partialChecksum, $checksumPath)
    $ownsChecksum = $false
    Write-Host "Verified release archive: $archivePath ($($files.Count) files)"
    Write-Host "SHA256: $archiveHash"
}
finally {
    if ($null -ne $zipStream) { $zipStream.Dispose() }
    foreach ($file in $files.Values) { if ($null -ne $file.Stream) { $file.Stream.Dispose() } }
    # Delete only partial files successfully created by this invocation, never final/user files.
    if ($ownsArchive) { Remove-Item -LiteralPath $partialArchive -Force }
    if ($ownsChecksum) { Remove-Item -LiteralPath $partialChecksum -Force }
}
