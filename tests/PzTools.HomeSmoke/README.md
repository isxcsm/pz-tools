# Home page standalone WinUI smoke test

Links the production `HomePage.xaml`/code-behind and artwork, and loads the real
`App.xaml` resource dictionary without constructing the production application.
It never starts AppHost, schedulers, a game connection, or reads user saves or
settings. The only output is written to the explicitly supplied output directory.

Run on Windows, serially with other builds of this repository:

```powershell
dotnet build tests/PzTools.HomeSmoke/PzTools.HomeSmoke.csproj -c Debug
$output = Join-Path (Get-Location) 'artifacts/home-smoke'
$exe = 'tests/PzTools.HomeSmoke/bin/Debug/net10.0-windows10.0.19041.0/win-x64/PzTools.HomeSmoke.exe'
$process = Start-Process -FilePath $exe -ArgumentList ('"' + $output + '"') -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(45000)) { throw 'Home smoke test did not complete within 45 seconds.' }
Get-Content -LiteralPath (Join-Path $output 'result.txt')
```

The window is hidden after its visual tree loads. If the local graphics driver
cannot render hidden WinUI content, append `--visible` to the executable arguments
and inspect the temporary test window; it still does not start any application
services.

Expected: exit code 0, `PASS` in `result.txt`, and four Home PNGs covering 1280×920 and
640×720 layout sizes in light/dark themes, plus two navigation SVG test strips.
The same Home instance is also switched through all 18 supported languages using
the production Localizer and PRI resources. Text, link labels, accessibility names,
and the page language are checked after every switch. Each language is rendered at
1040×920 and 640×920, with checks for clipping and an accessible footer.
Overflowing vertical content also gets
a `-bottom.png`. PNG output is normalized to those pixel dimensions; layout uses
DIPs at the machine's current system text scaling. `layout.json` records actual
CTA geometry, theme, rasterization scale, scroll height and any trimmed text.

Each of the five production CTA buttons is invoked through its real WinUI
automation peer in all four combinations, asserting exactly one expected
`NavigationRequested` event. The narrow viewport must exercise scrolling, and
each CTA is brought fully into view before invocation. Horizontal clipping,
vertically unreachable CTAs, missing/disabled CTAs, or an
unloaded bitmap artwork fail the run. The footer must also show the selectable
app version, independent of the test assembly's version metadata.

The production Home and Apps SVGs are loaded through `SvgImageSource` into 20 px
`ImageIcon` controls in both themes. Each must raise `Opened` and render nontransparent
pixels; a load failure, timeout or blank icon fails the run. The test strips are
minimal asset checks, not a complete navigation-shell capture.

PNG inspection remains necessary for contrast, spacing, visual hierarchy and
image cropping. The capture uses the standard themed application-page background,
not a live Mica desktop backdrop. This is a HomePage-only test, not a navigation-shell integration
test or a substitute for accessibility/large-text testing on additional systems.
`HomeNavigationUiSourceTests` separately checks the initial XAML visibility and
Home selection/pointer-focus contracts without launching the shell. It cannot
verify native startup focus visuals or the app's first rendered frame.
