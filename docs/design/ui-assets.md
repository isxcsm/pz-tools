# App icons and artwork

[Documentation index](../README.md)

Where the app's pictures live, what uses them, and how to change them without breaking the build or the licence
notices.

## Files

| Image | File | Used by |
| --- | --- | --- |
| Logo | `pztools.png` and `pztools.scale-125/150/200/300/400.png` in [Assets/Brand](../../src/PzTools.App/Assets/Brand) | The top of the navigation pane, beside the app name (56 pixels, 32 with the pane folded) |
| Logo master | `pztools-master.png` in [Assets/Brand](../../src/PzTools.App/Assets/Brand) | Editable source of the logo; not shipped |
| Home illustration | [pztools-home.png](../../src/PzTools.App/Assets/Brand/pztools-home.png) | The Home page |
| Windows icon | [pztools.ico](../../src/PzTools.App/Assets/Navigation/pztools.ico) | The executable (`ApplicationIcon`), the window (`AppWindow.SetIcon`, which covers the taskbar and Alt+Tab) and the tray icon |
| Windows icon source | [pztools.svg](../../src/PzTools.App/Assets/Navigation/pztools.svg) | Source the ICO is generated from; not shipped |
| Navigation icons | `home.svg`, `saves.svg`, `profiler.svg`, `extensions.svg`, `logs.svg`, `settings.svg` in [Assets/Navigation](../../src/PzTools.App/Assets/Navigation) | The navigation pane items, as 20-pixel `ImageIcon`s |
| Dead-character badge | [skull.svg](../../src/PzTools.App/Assets/Navigation/skull.svg) | Save and backup thumbnails of a dead character, and the character choice in the heal dialog |
| Support cup | A `Path` inline in [MainWindowShell.xaml](../../src/PzTools.App/MainWindowShell.xaml) | The **Buy me a coffee** button; its link is in [MainWindowShell.Support.cs](../../src/PzTools.App/MainWindowShell.Support.cs) |

Button and card glyphs (delete, restore, export, the card outcome icons and so on) are `FontIcon` glyphs from the
Windows icon font. They have no files.

[PzTools.App.csproj](../../src/PzTools.App/PzTools.App.csproj) copies every PNG in `Assets/Brand`, every SVG in
`Assets/Navigation` and the ICO to the build and publish output, except the two sources, `pztools-master.png` and
`pztools.svg`. A new asset in those folders ships without a project change; a new source file must be added to the
exclusions.

## Changing the logo

Update `pztools-master.png`, the base `pztools.png` and all five scale variants together, so every display scale shows
the same picture. Nothing in the repository generates them.

## Changing the Home illustration

Keep the PNG's alpha channel: the area outside the rounded badge is transparent and the page background shows through
it in both themes.

## Changing the Windows icon

The ICO holds 16, 20, 24, 32, 40, 48, 64, 128 and 256-pixel images, all rendered from the SVG.

1. Edit `pztools.svg`.
2. With Node.js and the `sharp` package available, run from the repository root:

   ```powershell
   node scripts/generate-app-icon.cjs
   ```

3. Commit the SVG and the regenerated ICO together.

The script ([generate-app-icon.cjs](../../scripts/generate-app-icon.cjs)) writes only the ICO. The repository does not
pin a `sharp` version. A normal build uses the committed ICO and does not need Node.js.

## Navigation icons

The icons are colour SVGs drawn at about 20 pixels in a 24-pixel box. The pane's icon box is raised to 24 pixels
(`NavigationViewItemOnLeftIconBoxHeight` in `MainWindowShell.xaml`) so WinUI does not shrink them again. A new menu
item needs a 24 × 24 SVG in `Assets/Navigation` in the same style. Its spacing is applied to every menu item in code,
so it needs no layout change.

## Third-party artwork

| Asset | Source | Changes |
| --- | --- | --- |
| `home.svg` | `ic_fluent_home_24_color.svg` from Microsoft's [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons/tree/a563cf9166f4f91aa617557ed272612b7f0a2f72) | Walls and door recoloured grey; the orange roof kept |
| `extensions.svg` | `ic_fluent_apps_24_color.svg` from the same set | None |
| Support cup | The cup from Buy Me a Coffee's button logo | Paths combined into one monochrome shape that follows the theme |

Their licences and attributions are in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md), which the build also
copies next to the app. Adding or replacing third-party artwork means updating that file in the same change.
