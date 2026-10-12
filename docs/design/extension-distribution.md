# Extension distribution (plan)

[Documentation index](../README.md)

> Plan, decided 2026-10-08. There is no release of the extension side before a long single-player test by the
> developer: the [startup loader](startup-loader.md) stays hidden behind its experimental setting until then. This
> page fixes the boundaries now, while they are cheap to draw, so that a later release does not have to move code
> that players already run.
>
> The extension API that Lua mods use left PZ Tools on 2026-10-12: it is PZ Extension API, a program of its own in
> its own repository, with its own loader, installer and releases. PZ Tools only carries a release of it to help
> install it ([PZ Extension API install](extension-api-install.md)). This page is about PZ Tools' own extension
> side.

## Goals

- The extension side (the extension runtime and its modules) is released apart from the app, and each part can be
  updated without the others.
- A player who uses no extension is not touched by any of it: nothing is downloaded, loaded or hooked for them.
- Releases come from GitHub releases of this repository. There is no update server.

## What there is today

All parts are built and versioned with the app and shipped in its `game-bridge\` folder
([layers](module-reload.md#layers)):

| Layer | File | Holds | Replaced in a running game |
| --- | --- | --- | --- |
| Bootstrap | `pztools-game-bootstrap.jar` | The socket, the game-loop hook and the extensions' module API | No |
| Payload | `pztools-game-bridge.jar` | The app's own work in the game (saves, WATCH, profiler, extension control) | Yes |
| Extension runtime | `extensions\pztools-extension-runtime.jar` | `ModuleHost`, `ContinuousRuntime` | Yes |
| Modules | `extensions\*.jar`, listed in `catalog.tsv` | One extension each | Yes, each in its slot |

The startup loader copies these into `%ProgramData%\PzTools\startup\s-<account>\bridge-<digest>\` and points
`current` at the copy the next game loads ([installed files](startup-loader.md)). The app asks GitHub for
`releases/latest` and reads its tag as `v<version>` ([`UpdateChecker`](../../src/PzTools.App.Core/UpdateChecker.cs)).

## Release units

| Unit | Contents | Released as | Who gets it |
| --- | --- | --- | --- |
| App | The app, the bootstrap, the payload's core | Tag `v<version>`, as today | Every player |
| Extension runtime and modules | The runtime jar, each module jar, the catalogue | Tag `ext-<module>-v<version>` per module | Players who turned that module on |

The bootstrap stays with the app. Every player loads it, and it can only change with a game restart.

## Boundaries to draw before any release

### 1. A manifest for every unit

Each release unit carries `component.json` next to its files, and its release attaches both with a signature:

| Field | Example | Use |
| --- | --- | --- |
| `id` | `pztools.vehicle-drivetrain` | Which unit |
| `version` | `3.1.0` | Newer than the installed one to be offered |
| `requires` | `{ "bootstrapApi": 13, "extensionAbi": 3, "app": "0.3.0" }` | Offered only when the installed parts meet it; the existing jar manifest checks (`PzTools-Bootstrap-Api`, `PzTools-Extension-Api`) stay the final word in the game |
| `files` | `[{ "name": "pztools-vehicle-drivetrain.jar", "sha256": "…" }]` | Checked after download and again by the loader, as it checks the bootstrap's digest today |

The signature is over `component.json` with a key whose public half is built into the app. A unit whose signature
or digests do not match is not installed and not loaded. Downloads go into a new `bridge-<digest>` folder beside the
current one and `current` is switched only once the copy is complete, so a failed or partial download leaves the
working install as it was.

### 2. Tags and "latest"

- App releases keep the tag `v<version>` for good: apps already installed read only `releases/latest` and only that
  tag form ([`ParseVersion`](../../src/PzTools.App.Core/UpdateChecker.cs)).
- Extension releases are published with **Set as latest release** off. If one became latest, every installed app
  would read a tag it cannot parse and stop seeing app updates, silently.
- The app's checker moves to listing releases (one request, `releases?per_page=100`) and taking the newest of each
  tag prefix it uses, so that a release marked latest by mistake cannot hide anything from new apps.
- One repository serves all of these. A unit moves to a repository of its own only when its code does, as PZ
  Extension API did.

## Players who use no extension

The app downloads no extension unit unless the player turned a module on (that module and the runtime). The update
notice for the app does not depend on any extension release. Uninstalling the loader removes its folder; nothing of
the extension side stays in the app's own folder.

## Order

1. Now: this page.
2. When a release is decided: manifests and signing (1), the tag rules and the checker change (2), and downloads.

## Open questions

- Where the signing key lives and how it is rotated.
- Whether a module's tuning file (`vehicle-drivetrain.toml`) is part of its unit or of the app.
