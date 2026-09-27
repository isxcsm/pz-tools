# App icons and branding

[Documentation index](README.md) · [User guide](../README.md)

The navigation rail displays the raster artwork in [Assets/Brand](../src/PzTools.App/Assets/Brand), beside the app name and localized subtitle. Keep `pztools-master.png`, the base `pztools.png`, and its display-scale variants together when changing the artwork.

The Windows icon has a separate vector source, [pztools.svg](../src/PzTools.App/Assets/Navigation/pztools.svg). The generated `pztools.ico` is used by the executable and `AppWindow.SetIcon`, including the taskbar and Alt+Tab. The ICO contains 16, 20, 24, 32, 40, 48, 64, 128, and 256 px images. Build and publish copy the runtime icon and brand assets.

After editing the SVG, regenerate the ICO from the repository root with Node.js and `sharp` installed:

```powershell
node scripts/generate-app-icon.cjs
```

Commit both the SVG and ICO. The recorded generation environment used `sharp` 0.35.4; ordinary Visual Studio builds use the committed ICO and do not require Node.js. This script does not generate the larger raster brand artwork.

Other navigation icons and the dead-character badge are in [Assets/Navigation](../src/PzTools.App/Assets/Navigation). The support button's cup graphic is inline in [MainWindowShell.xaml](../src/PzTools.App/MainWindowShell.xaml), with its destination in [MainWindowShell.Support.cs](../src/PzTools.App/MainWindowShell.Support.cs).
