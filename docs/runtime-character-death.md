# Live character death and save execution observations

[Documentation index](README.md) · [Runtime pause policy](runtime-pause-backups.md) · [Game extensions](game-extensions.md)

## Separate facts and owners

`CharacterState` in the save discovery/database pipeline still describes data persisted
in `players.db`. It is used for save information and is not overwritten by a JVM reading.
That pipeline no longer has a death-backup option or emits death-backup commands.

`RuntimeCharacterLife` is an independent live fact (`Unknown`, `Alive`, `Dead`). The
existing JVM runtime observer reads the sole local player on the game thread using
cached reflective access. It does not read SQLite, serialize inventory, save the game,
or create another attachment, thread, periodic scanner or per-frame event collection.
An unavailable player/API or multiple local players is Unknown, not Alive or Dead.

A world/player identity uses weak references; a positively observed Alive → Dead edge
creates one death ID. First observation of an already-dead character is not a new death.
Repeated dead observations and subscription reconnects preserve the existing episode ID.
A new character or resurrection starts a new life; there is no synthetic death on reconnect.
As with the existing observer, this is sampled state, not a guaranteed lossless game event
journal: a character removed before observation cannot be reconstructed from a DB flag.

## From observation to backup

`STATE4` carries life, character identity, death ID, sleep and an optional last save execution
report through the existing authenticated runtime feed. The state reactor commits a
semantic transition and its outbox; scheduling consumes it transactionally.

The scheduler records one latest consumed death identity, including while either death
backups or automatic backups are disabled. It queues at most one pending run per episode.
No delayed death is replayed merely because a user enables an option or the observer
reconnects. Older DB-derived state-transition death commands are retired, not replayed.

Death work has an exact process/world/character/death guard. The game checks that guard
again immediately before saving. An expired episode or new character cannot receive an
old death backup. Pause and the periodic active-time deadline do not suppress a death
backup; the automatic-backup master switch and death option still apply. Missing live
state never falls back to a DB-derived death decision. Explicit pre-save deferral can
retry the same pending episode; started failures/unknown completion are not replayed.

Standard saving keeps this admission rule. Once actual saving begins,
a later pause/disconnect does not abandon outstanding writes. Save-before-backup and the
existing configuration policy retain their meaning; an observation alone does not
confirm that game data was saved to disk.

## Save execution feedback

The shared protocol can retain one immutable report for its last admitted provider request:
requested provider, actual provider, Running/Succeeded/Failed, fallback/error code,
game-thread preparation milliseconds and total elapsed milliseconds. It holds no world
objects, growing history, credentials or arbitrary exception text.

The report follows the same read-only runtime stream. App.Core projects a fresh report
for the current process/world; WinUI only renders that view. Version preference and
actual outcome remain distinct. A disabled toggle is not switched on by an old success.
Fallback is shown as standard saving, not extension success. Stale/disconnected or
other-world reports are not displayed as current execution.

The provider contract remains for compatibility and synthetic tests; no optional save
provider is shipped. Backups use the original game save. Report timing is request
timing, not a frame-time profiler or proof of faster gameplay.

## Validation boundary

Tests use synthetic JVMs and temporary SQLite/files, not the user's game or saves.
They verify death while a stored DB flag remains Alive, death during pause, replay and
character replacement, initially dead/multiple-player states, option gating, durable
pending work, old-command retirement and projection of real execution outcomes.

The installed B42.20 GameWindow, PlayerDB, VehiclesDB2, ExceptionLogger and IsoChunk
classes were read and transformed in memory; all five passed ClassFile structural
verification. This does not execute game code, perform a live attach or establish save
consistency/performance with actual vehicles and mods.
Actual gameplay, rendered UI and end-to-end vehicle/item restoration require separate
acceptance. Use test output for the commit being evaluated, not historical suite counts.
