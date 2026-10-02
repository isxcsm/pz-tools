# Updating code inside a running game

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

PZ Tools puts some of its code into the running game: the [save bridge](save-bridge.md)
and the [game extensions](game-extensions.md). When PZ Tools is updated while the game
is still running, that code is usually updated too, without restarting the game. This
page explains when that works, when a restart is needed, and what is kept safe during
the switch.

## In short

- Most updates are picked up automatically the next time PZ Tools talks to the game:
  at the next backup request or the next extension-control message.
- Work that is already running is never interrupted. A save in progress finishes on
  the old code; the new code is loaded afterwards.
- Only an incompatible **bootstrap**, the small part that stays in the game for its
  whole session, needs a game restart. The [compatibility table](save-bridge.md#compatibility-and-lifecycle)
  lists the current versions.
- The app itself may still need a restart to use its own updated files.

## What happens for each kind of change

| What changed | What happens |
| --- | --- |
| Nothing (same files, same catalogue entry) | The loaded code keeps running |
| A module's archive, or its catalogue entry | The old module is retired, then the new one is started |
| The extension runtime | All modules are retired and the runtime is closed, then the new runtime is loaded |
| The bridge payload | The state stream is stopped politely, calls in progress finish, the payload is swapped, and the stream reconnects |
| The same files in a different folder (the app was moved) | The new folder is used; the hook in the game loop is not installed again |
| The new archive is broken or invalid | It is rejected; the running module stays as it is |
| A save or a cleanup is still in progress | Nothing is replaced until it is finished |
| The old code could not be retired cleanly, or the bootstrap is incompatible | Nothing new is loaded and no save is replayed. The game has to be restarted. |

Changing an extension's *settings* is not an update of its code: settings are applied
to the running module at its own [safe boundary](glossary.md#safe-boundary). The
[settings revision](glossary.md#settings-revision) shows whether the game is using the
settings you saved yet.

## What stays safe during the switch

**Saves.** A save the game has accepted belongs to the request that started it until
the game's save call returns, even if the connection drops. A replacement never
starts that save again. Queueing, cancellation and deadlines are described under
[when the game is not saved](save-bridge.md#admission-and-failures).

**The state stream.** Replacing a module or the extension runtime leaves the
[WATCH](glossary.md#watch) stream running. Replacing the payload briefly ends it, and
the state scheduler reconnects. The process, world, character and death identities are
kept in the bootstrap, so they survive. What changes is the
[observer epoch](glossary.md#observer-epoch): readings and [tickets](glossary.md#ticket)
from before the switch become invalid, so an old reading cannot trigger a backup. A
death that was already reported is not reported again.

**Modules.** A module is replaced only after the old copy is fully
[retired](glossary.md#retire-revoke): no new calls are let in, calls in progress
finish, and everything it held is released. Only then can the next
[generation](glossary.md#generation-module) use those resources. Modules have to
support retirement explicitly. For the vehicle module this also covers an expired
control lease, a change of game process or world, and being cut off while the game is
paused; see the [vehicle design](vehicle-drivetrain-design.md#replacement-and-failure-handling).

## Details

- **One read per archive.** An archive's bytes are read once into memory. Checking
  the manifest, hashing and loading classes all use those same bytes, so a file that
  changes halfway cannot mix two versions.
- **A half-written archive does no harm.** If a newly written archive cannot be
  opened, the running module is not touched.
- **Known-bad versions are remembered.** A module whose start-up is unsupported is
  not tried again for that exact archive and definition. A corrected archive is tried.
- **A cleanup that times out stops everything new.** The host is marked unusable and
  no other version is loaded until the game restarts
  ([restart required](glossary.md#restart-required)).
- **Classes are not unloaded.** Retiring a module releases its effects and references.
  It does not force Java to unload the old classes, which stay in memory until the game
  exits.

## Verification

An automated harness uses synthetic modules to test:

- work that is still in flight during a switch
- changed archives, and moving the app to another folder
- replacing the extension runtime and the payload
- retirement that fails
- observer epochs, stable identities, invalidated tickets, and that the game-loop hook
  is installed only once

The vehicle tests add control ownership, settings revisions and cleanup. For a given
build, check its test results and package checks. How the switch behaves in a real
game is part of the [vehicle test guide](e2e-vehicle-drivetrain.md).
