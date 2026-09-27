[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) {
    throw 'Documentation checks require Python 3.10 or later on PATH.'
}
# Preserve the existing entry point; both CI platforms use the same offline checker.
& $python.Source (Join-Path $PSScriptRoot 'check-documentation.py')
if ($LASTEXITCODE -ne 0) {
    throw "Documentation checks failed (exit code $LASTEXITCODE)."
}
