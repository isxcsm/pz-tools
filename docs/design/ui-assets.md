# App icons and branding

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

This page is for anyone changing the pictures in the PZ Tools app: the logo, the Windows
icon, the Home page illustration and the navigation icons. It says where each file is,
what it is used for, and how to update it without breaking the build or the licence
notices.

## Where each image is used

| Image | File | Used for |
| --- | --- | --- |
| Brand logo | `pztools.png` and its display-scale variants (`pztools.scale-*.png`) in [Assets/Brand](../../src/PzTools.App/Assets/Brand) | The navigation rail, beside the app name and the localized subtitle |
| Brand master | `pztools-master.png` in [Assets/Brand](../../src/PzTools.App/Assets/Brand) | Editable source of the brand logo; not shipped |
| Home illustration | [pztools-home.png](../../src/PzTools.App/Assets/Brand/pztools-home.png) | The Home page |
| Windows icon | `pztools.ico` in [Assets/Navigation](../../src/PzTools.App/Assets/Navigation) | The executable and `AppWindow.SetIcon`, which covers the taskbar and Alt+Tab |
| Windows icon source | [pztools.svg](../../src/PzTools.App/Assets/Navigation/pztools.svg) | Vector source the ICO is generated from; not shipped |
| Navigation icons and dead-character badge | Other files in [Assets/Navigation](../../src/PzTools.App/Assets/Navigation) | The navigation pane and the save list |
| Support button cup | Inline in [MainWindowShell.xaml](../../src/PzTools.App/MainWindowShell.xaml) | The support button; its destination is in [MainWindowShell.Support.cs](../../src/PzTools.App/MainWindowShell.Support.cs) |

Build and publish copy the runtime icon and brand assets to the output. The editable
sources, `pztools-master.png` and `pztools.svg`, are left out.

## Changing the brand logo

Keep `pztools-master.png`, the base `pztools.png` and its display-scale variants
together: when one changes, update the others to match.

## Changing the Home illustration

`pztools-home.png` is based on an illustration the user provided. The only edit was to
make the black area outside the badge transparent, using the built-in image editor.
When updating it, keep:

- the PNG's alpha channel
- the blue scene inside the rounded badge

## Changing the Windows icon

The ICO contains 16, 20, 24, 32, 40, 48, 64, 128 and 256 px images, all generated from
the SVG.

1. Edit `pztools.svg`.
2. With Node.js and `sharp` installed, regenerate the ICO from the repository root:

   ```powershell
   node scripts/generate-app-icon.cjs
   ```

3. Commit both the SVG and the ICO.

The recorded generation environment used `sharp` 0.35.4. Ordinary Visual Studio builds
use the committed ICO and do not need Node.js.

## Limits

- The icon script generates only the ICO. It does not produce the larger raster brand
  artwork in `Assets/Brand`.

## Third-party icons

The Home and game-extension navigation icons come from Microsoft's
[Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons/tree/a563cf9166f4f91aa617557ed272612b7f0a2f72):

| Navigation icon | Source file |
| --- | --- |
| Home | `Home/SVG/ic_fluent_home_24_color.svg`, keeping its orange roof with gray walls and door |
| Game extensions | `Apps/SVG/ic_fluent_apps_24_color.svg`, unchanged |

Their MIT license is included in the [third-party notices](../../THIRD_PARTY_NOTICES.md).
