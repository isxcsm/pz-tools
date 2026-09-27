# Extension section smoke check

This isolated WinUI executable links the production `ExtensionSettingsSection`,
localizer and language resources. It renders wide/narrow light/dark layouts and
checks preference switches, persistent collapse state and runtime hints. It does
not instantiate `AppHost`, connect to a game or read/write user settings or saves.

```powershell
dotnet build tests/PzTools.ExtensionsSmoke/PzTools.ExtensionsSmoke.csproj -c Release
Start-Process -WindowStyle Hidden -Wait `
  tests/PzTools.ExtensionsSmoke/bin/Release/net10.0-windows10.0.19041.0/win-x64/PzTools.ExtensionsSmoke.exe `
  -ArgumentList 'C:\absolute\output-folder'
```

The output folder contains `result.txt` and rendered PNG files. Exit code 1 or a
`FAIL` result indicates a failed check. Review the captures for visual quality;
the assertions do not substitute for that review.
