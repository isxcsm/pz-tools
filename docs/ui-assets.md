# App icons and branding

[Documentation index](README.md) · [User guide](../README.md)

The navigation rail displays the raster artwork in [Assets/Brand](../src/PzTools.App/Assets/Brand), beside the app name and localized subtitle. Keep `pztools-master.png`, the base `pztools.png`, and its display-scale variants together when changing the artwork.

The home page uses [pztools-home.png](../src/PzTools.App/Assets/Brand/pztools-home.png).
It is based on the user-provided illustration, with only the black exterior made
transparent using the built-in image editor. Preserve the PNG's alpha channel and
the blue scene inside the rounded badge when updating it.

The Windows icon has a separate vector source, [pztools.svg](../src/PzTools.App/Assets/Navigation/pztools.svg). The generated `pztools.ico` is used by the executable and `AppWindow.SetIcon`, including the taskbar and Alt+Tab. The ICO contains 16, 20, 24, 32, 40, 48, 64, 128, and 256 px images. Build and publish copy the runtime icon and brand assets, excluding the editable `pztools-master.png` and `pztools.svg` sources.

After editing the SVG, regenerate the ICO from the repository root with Node.js and `sharp` installed:

```powershell
node scripts/generate-app-icon.cjs
```

Commit both the SVG and ICO. The recorded generation environment used `sharp` 0.35.4; ordinary Visual Studio builds use the committed ICO and do not require Node.js. This script does not generate the larger raster brand artwork.

Other navigation icons and the dead-character badge are in [Assets/Navigation](../src/PzTools.App/Assets/Navigation). The support button's cup graphic is inline in [MainWindowShell.xaml](../src/PzTools.App/MainWindowShell.xaml), with its destination in [MainWindowShell.Support.cs](../src/PzTools.App/MainWindowShell.Support.cs).

The Home and game-extension navigation icons use Microsoft's [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons/tree/a563cf9166f4f91aa617557ed272612b7f0a2f72): `Home/SVG/ic_fluent_home_24_color.svg` and `Apps/SVG/ic_fluent_apps_24_color.svg`. The Home icon retains its orange roof with gray walls and door; Apps is unchanged. Their MIT license is included in [third-party notices](../THIRD_PARTY_NOTICES.md).
