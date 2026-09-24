[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repoRoot 'src/PzTools.Process.Contracts/Localization/languages.tsv'
$locales = @(Get-Content -LiteralPath $catalogPath -Encoding utf8 | ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) { ($_ -split "`t")[1] }
})
$guides = @($locales | ForEach-Object {
    if ($_ -eq 'en-US') { 'README.md' } else { "docs/$_/README.md" }
})
$linkCount = 0

foreach ($guide in $guides) {
    $path = Join-Path $repoRoot $guide
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing README: $guide"
    }
    $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
    $baseDirectory = Split-Path -Parent $path
    $targets = @()
    # These authored guides use inline Markdown links and HTML href/src attributes.
    $pattern = '\]\(([^)]+)\)|(?:href|src)="([^"]+)"'
    foreach ($match in [regex]::Matches($content, $pattern)) {
        $href = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        if ($href -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { continue }
        $parts = $href -split '#', 2
        $target = if ($parts[0]) {
            [IO.Path]::GetFullPath((Join-Path $baseDirectory $parts[0]))
        } else { $path }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Broken link in ${guide}: $href"
        }
        if ($parts.Length -eq 2 -and $parts[1]) {
            $targetContent = Get-Content -LiteralPath $target -Raw -Encoding utf8
            $anchors = @([regex]::Matches($targetContent, '(?m)^#{1,6}\s+(.+?)\r?$') | ForEach-Object {
                $_.Groups[1].Value.ToLowerInvariant() -replace '[^\p{L}\p{N}\p{M}_\-\s]', '' -replace '\s', '-'
            })
            if ($parts[1] -notin $anchors) { throw "Missing heading in ${guide}: $href" }
        }
        $targets += $target
        $linkCount++
    }
    # Every guide must link to every other supported locale.
    foreach ($other in $guides) {
        if ($other -ne $guide -and [IO.Path]::GetFullPath((Join-Path $repoRoot $other)) -notin $targets) {
            throw "Missing language link in ${guide}: $other"
        }
    }
}

Write-Output "README checks passed: $($guides.Count) locales, $linkCount local links and images."
