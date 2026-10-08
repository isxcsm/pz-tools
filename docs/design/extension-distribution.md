# Extension distribution (plan)

[Documentation index](../README.md)

> Plan, decided 2026-10-08; of it only the API's own jar (boundary 1) is built. There is no release of the extension side before a long
> single-player test by the developer: the [startup loader](startup-loader.md) stays hidden behind its experimental
> setting until then. This page fixes the boundaries now, while they are cheap to draw, so that a later release
> does not have to move code that players already run.

## Goals

- The extension side (the [extension API](extension-api.md), the extension runtime and its modules) is released
  apart from the app, and each part can be updated without the others.
- A player who uses no extension is not touched by any of it: nothing is downloaded, loaded or hooked for them.
- Releases come from GitHub releases of this repository. There is no update server.
- Later, the extension API and the Lua mods built on it may also be offered on the Steam Workshop.

## What there is today

All parts are built and versioned with the app and shipped in its `game-bridge\` folder
([layers](module-reload.md#layers)):

| Layer | File | Holds | Replaced in a running game |
| --- | --- | --- | --- |
| Bootstrap | `pztools-game-bootstrap.jar` | The socket, the game-loop hook, the extension API's hooks into game classes (`ApiHooks`) and its shared classes | No |
| Payload | `pztools-game-bridge.jar` | The app's own work in the game (saves, WATCH, profiler, extension control) | Yes |
| Extension API | `extensions\pztools-extension-api.jar` | The extension API's implementation (`pztools.api`: buildings, power and water networks), loaded only in a game the startup loader started | Yes |
| Extension runtime | `extensions\pztools-extension-runtime.jar` | `ModuleHost`, `ContinuousRuntime` | Yes |
| Modules | `extensions\*.jar`, listed in `catalog.tsv` | One extension each | Yes, each in its slot |

The startup loader copies these into `%ProgramData%\PzTools\startup\s-<account>\bridge-<digest>\` and points
`current` at the copy the next game loads ([installed files](startup-loader.md)). The app asks GitHub for
`releases/latest` and reads its tag as `v<version>` ([`UpdateChecker`](../../src/PzTools.App.Core/UpdateChecker.cs)).
Lua mods that use the API, such as Building Utilities, live in their own repositories.

## Release units

| Unit | Contents | Released as | Who gets it |
| --- | --- | --- | --- |
| App | The app, the bootstrap, the payload's core | Tag `v<version>`, as today | Every player |
| Extension API | The API's implementation jar | Tag `api-v<version>` | Players with the startup loader installed |
| Extension runtime and modules | The runtime jar, each module jar, the catalogue | Tag `ext-<module>-v<version>` per module; the runtime with the API's release | Players who turned that module on |
| Lua mods | A mod folder | Its own repository, later the Workshop | Players who subscribe |

The bootstrap stays with the app. Every player loads it, it can only change with a game restart, and the API's
hooks in it are installed only in a game the startup loader started, so a player without the loader never runs
them. An API release that needs newer hooks says so in its manifest (below) and waits for the app update that
brings them.

## Boundaries to draw before any release

### 1. The API's implementation in its own jar

Done 2026-10-08 ([extension API reload](module-reload.md#extension-api)): `pztools.api` is in
`extensions\pztools-extension-api.jar`, loaded only in a game the startup loader started, the way the extension
runtime jar is, with the same takeover in a running game. An API fix ships without the payload, an app update that
changes the payload does not reload the networks of every Lua mod, and an attach-only game never loads the API's
code at all.

### 2. A manifest for every unit

Each release unit carries `component.json` next to its files, and its release attaches both with a signature:

| Field | Example | Use |
| --- | --- | --- |
| `id` | `pztools.extension-api` | Which unit |
| `version` | `3.1.0` | Newer than the installed one to be offered |
| `requires` | `{ "bootstrapApi": 11, "extensionAbi": 3, "app": "0.3.0" }` | Offered only when the installed parts meet it; the existing jar manifest checks (`PzTools-Bootstrap-Api`, `PzTools-Extension-Api`) stay the final word in the game |
| `files` | `[{ "name": "pztools-extension-api.jar", "sha256": "…" }]` | Checked after download and again by the loader, as it checks the bootstrap's digest today |

The signature is over `component.json` with a key whose public half is built into the app (and, for the Workshop
case below, into the loader). A unit whose signature or digests do not match is not installed and not loaded.
Downloads go into a new `bridge-<digest>` folder beside the current one and `current` is switched only once the
copy is complete, so a failed or partial download leaves the working install as it was.

### 3. Tags and "latest"

- App releases keep the tag `v<version>` for good: apps already installed read only `releases/latest` and only that
  tag form ([`ParseVersion`](../../src/PzTools.App.Core/UpdateChecker.cs)).
- Extension releases are published with **Set as latest release** off. If one became latest, every installed app
  would read a tag it cannot parse and stop seeing app updates, silently.
- The app's checker moves to listing releases (one request, `releases?per_page=100`) and taking the newest of each
  tag prefix it uses, so that a release marked latest by mistake cannot hide anything from new apps.
- One repository serves all of these. The Java units share the build and move with every API change, so separate
  repositories would turn each change into a cross-repository version dance. A unit moves to a repository of its
  own only when its code does: someone else's extension, or a Lua mod (already separate).

### 4. Mods test features, not versions

Lua mods ask the API for what they need and fall back when it is refused (`PZToolsAPI.hooks()`, a policy the API
refuses: [extension API](extension-api.md)), never compare its version. Units then update in any order without
breaking a mod that runs on an older or newer API.

## Players who use no extension

The app downloads no extension unit unless the startup loader is installed (the API) or the player turned a
module on (that module and the runtime). The update notice for the app does not depend on any extension release.
Uninstalling the loader removes its folder; nothing of the extension side stays in the app's own folder.

## The Steam Workshop, later

- A Workshop item cannot install the loader: it delivers files into the Workshop folder and the game loads only
  Lua and media from it. The loader is installed once by the app (or a small installer made from it).
- With the loader installed, a Workshop item could carry the extension API unit, and the loader would load it from
  there when its signature matches the built-in key: Workshop updates then update the API. Lua mods on the API are
  ordinary Workshop items that depend on it.
- Loading code from a Workshop folder is code from a subscription; the signature check is what keeps it to ours.

## Order

1. Now: this page.
2. Boundary 1 (the API jar): done 2026-10-08.
3. When a release is decided: manifests and signing (2), the tag rules and the checker change (3), downloads, and
   the Workshop question.

## Open questions

- One API unit for all Lua mods, or the networks engine and the building facts as separate units.
- Where the signing key lives and how it is rotated.
- Whether a module's tuning file (`vehicle-drivetrain.toml`) is part of its unit or of the app.
