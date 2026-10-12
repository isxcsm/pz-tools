# PZ Extension API install

[Documentation index](../README.md)

> **Built, hidden.** The card shows with the [startup loader](startup-loader.md)'s, only with
> `[experimental] startup_loader = true` in the app's advanced settings.

PZ Extension API (PZExtAPI) is a program of its own, in its own repository (`pz-extension-api`): Java
hooks the game loads as it starts, which Lua mods use through the `PZExtAPI` global. It does not need
PZ Tools, and PZ Tools does not need it. Its design, files and installer are documented there.

PZ Tools only helps to install it:

- The app carries a release of it in its `extension-api` folder. The build copies it from
  `..\pz-extension-api\out\release` (the property `ExtensionApiRelease`); without one there, the build
  warns and the card says the app carries none.
- The game extensions page has a switch for it
  ([`ExtensionApiInstall`](../../src/PzTools.App.Core/ExtensionApiInstall.cs)). It runs the release's
  own installer, `pzext-install.jar status|install|uninstall <game folder>`, with the bridge's Java
  runtime, and only while no game runs. The installer prints one result line (`PZEXT-INSTALL` or
  `PZEXT-INSTALL-FAILED`); the app reads nothing else from it.
- While it is installed and one game runs, the app reads the API's install folder
  (`%ProgramData%\PZExtAPI\s-<account>`): `loader.log` says whether this game run loaded it, and
  `api.tsv` names the hooks that could not go in. The card says so, and each finding goes to the log once.

Nothing of PZ Extension API is in the bridge: the bootstrap, the payload and the startup loader know
nothing of it. Uninstalling PZ Tools leaves an installed PZ Extension API in place; its own installer
removes it.
