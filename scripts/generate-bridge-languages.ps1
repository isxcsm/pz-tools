param(
    [Parameter(Mandatory=$true)][string] $Catalog,
    [Parameter(Mandatory=$true)][string] $OutputFile,
    # The notes shown over the player for what the app did at the player's request: a key, then one column per language.
    [string] $Notices
)
$ErrorActionPreference = 'Stop'
function Literal([string] $row) { '        "' + $row.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t') + '",' }
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('package pztools.bridge.runtime;')
$lines.Add('// Generated from the shared language catalog. Do not edit.')
$lines.Add('final class NoticeLanguageData {')
$lines.Add('    static final String[] ROWS = {')
foreach ($row in [IO.File]::ReadAllLines($Catalog, [Text.Encoding]::UTF8)) {
    if ($row.Split("`t").Length -ne 10) { throw 'Invalid language catalog entry.' }
    $lines.Add((Literal $row))
}
$lines.Add('    };')
$lines.Add('    static final String[] NOTICE_ROWS = {')
if ($Notices) {
    $rows = [IO.File]::ReadAllLines($Notices, [Text.Encoding]::UTF8) | Where-Object { $_.Length -gt 0 }
    $columns = $rows[0].Split("`t").Length
    foreach ($row in $rows) {
        if ($row.Split("`t").Length -ne $columns) { throw "Invalid notice catalog entry: $($row.Split("`t")[0])" }
        $lines.Add((Literal $row))
    }
}
$lines.Add('    };')
$lines.Add('    private NoticeLanguageData() {}')
$lines.Add('}')
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputFile)) | Out-Null
[IO.File]::WriteAllLines($OutputFile, $lines, [Text.UTF8Encoding]::new($false))
