# WinUI tooltip smoke test

This standalone Windows test links the production `AppToolTip.cs` and opens a
tooltip in a loaded WinUI visual tree. It does not start the application host, schedulers,
game bridge, or access user saves/settings. The test window is hidden after load.

```powershell
dotnet build tests/PzTools.TooltipSmoke/PzTools.TooltipSmoke.csproj -c Debug
$result = Join-Path (Get-Location) 'artifacts/tooltip-smoke.txt'
$process = Start-Process -FilePath 'tests/PzTools.TooltipSmoke/bin/Debug/net10.0-windows10.0.19041.0/win-x64/PzTools.TooltipSmoke.exe' -ArgumentList $result -WindowStyle Hidden -PassThru
$process.WaitForExit(15000)
Get-Content -LiteralPath $result
```

Expect exit code 0 and a `PASS` result. Checks cover first open (including the
required native owner registration), stable tooltip identity after repeated
refreshes, content changes while open, dismissal, reopening, clearing the reason,
and reusing the tooltip. This is a lifecycle test, not a mouse/visual placement test.
