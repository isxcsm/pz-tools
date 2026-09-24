param(
    [Parameter(Mandatory=$true)][string] $Catalog,
    [Parameter(Mandatory=$true)][string] $OutputFile
)
$ErrorActionPreference = 'Stop'
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('package pztools.bridge.runtime;')
$lines.Add('// Generated from the shared language catalog. Do not edit.')
$lines.Add('final class NoticeLanguageData {')
$lines.Add('    static final String[] ROWS = {')
foreach ($row in [IO.File]::ReadAllLines($Catalog, [Text.Encoding]::UTF8)) {
    if ($row.Split("`t").Length -ne 9) { throw 'Invalid language catalog entry.' }
    $literal = $row.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t')
    $lines.Add('        "' + $literal + '",')
}
$lines.Add('    };')
$lines.Add('    private NoticeLanguageData() {}')
$lines.Add('}')
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputFile)) | Out-Null
[IO.File]::WriteAllLines($OutputFile, $lines, [Text.UTF8Encoding]::new($false))
