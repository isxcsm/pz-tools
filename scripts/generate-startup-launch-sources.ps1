param(
    [Parameter(Mandatory=$true)][string] $SourceDirectory,
    [Parameter(Mandatory=$true)][string] $OutputDirectory
)
# The startup loader's classes again under another package name (pztools.launch): the install puts them in a jar of
# its own and lists that jar in the launcher file's class path, so a copy of the loose classes made by another tool
# (PZ Optimize's AOT step) can never take their place (docs/design/startup-loader.md).
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Join-Path $OutputDirectory 'pztools/launch') | Out-Null
foreach ($file in Get-ChildItem $SourceDirectory -Filter '*.java') {
    $source = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
    if (-not $source.Contains('package pztools.startup;')) { throw "$($file.Name) has no package line." }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory "pztools/launch/$($file.Name)"),
        $source.Replace('package pztools.startup;', 'package pztools.launch;'), [Text.UTF8Encoding]::new($false))
}
