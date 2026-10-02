# Death backups

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

When your character dies, PZ Tools stops making automatic backups, so the backups made
while the character was alive are not pushed out of the kept number
([retention](glossary.md#retention)). If you want a copy of the moment of death as
well, turn on **Back up when the character dies** (`[backup].backup_on_death`, off by
default): PZ Tools then makes one backup when the death happens. This page is for
players who want to know when that backup is made and why periodic backups stop.

Deaths are read live from the running game through the
[save bridge](glossary.md#save-bridge), not from the save files.

## What happens when your character dies

1. PZ Tools sees the character go from alive to dead.
2. Periodic backups are held, whether or not the death option is on. The countdown
   line shows *Character dead – backups waiting* (internally `ScheduleHold.CharacterDead`).
3. If **Back up when the character dies** is on, one death backup is made. Pausing
   the game and the periodic countdown do not hold it back. The main switch for
   automatic backups still applies.
4. When you play a new character, periodic backups resume with a fresh interval.

While the character is dead, the active-time countdown is reset to a full interval and
does not run down, so a new character starts a fresh interval. With wall-clock
scheduling (see [game-aware timing](runtime-pause-backups.md)) a backup that falls due
simply stays due and runs once a living character is seen. The death option only
decides whether one backup of the moment of death is made.

Once the game has actually started saving for a death backup, pausing or a lost
connection does not abandon the writes still outstanding. **Save game before backup**
and the other existing settings mean the same for death backups as for any other. When
the game cannot be reached at all, a death backup uses the files on disk, like manual
and periodic backups; see
[when the game cannot be read](runtime-pause-backups.md#when-the-game-cannot-be-read).

## What counts as a death

The game reports the character as `Unknown`, `Alive` or `Dead`. A player or game API
that cannot be read, or more than one local player, counts as `Unknown`, never as alive
or dead.

- Only a change from `Alive` to `Dead` that PZ Tools actually sees is a new death. It
  gets one death ID.
- A character that is already dead the first time PZ Tools looks is not a new death.
- Seeing the same dead character again, or reconnecting to the game, keeps the same
  death ID. Reconnecting never invents a death.
- A new character, or a resurrection, starts a new life.

**One death, at most one backup.** The scheduler remembers the latest death it has
handled, even while death backups or automatic backups are switched off, and queues at
most one pending death backup per death. Turning the option on afterwards, or a
reconnect to the game, does not replay a death that has already passed.

**A backup only for the death it belongs to.** Each death backup is tied to one game
process, world, character and death. The game checks this once more immediately before
saving, so a death that has expired, or a new character, cannot receive an old death
backup. If the backup is explicitly deferred before the save starts, the same pending
death can be tried again. A backup that started and failed, or whose outcome is
unknown, is not replayed.

## Limits

- **Sampled, not logged.** Life and death are read at intervals, like the rest of the
  game state; they are not a complete record of game events. A character removed before
  PZ Tools looked cannot be reconstructed from a flag in the save database.
- **No fallback to the save files.** If the live reading is missing, PZ Tools never
  decides about a death from what `players.db` says instead.
- **A reading is not a save.** Seeing the death does not confirm that the game has
  written its data to disk.

## How it works inside

### Two separate records of the character

`CharacterState`, in the save discovery and database pipeline, describes what is stored
in `players.db`. It is used for save information and is never overwritten by a reading
from the running game. That pipeline has no death-backup option and emits no
death-backup commands. Death commands from older versions, which were derived from
state transitions in the database, are retired rather than replayed.

`RuntimeCharacterLife` is a separate, live fact. The existing game-state observer reads
the sole local player on the game thread, using cached reflective access. It does not
read SQLite, serialize inventory or save the game, and it creates no extra attachment,
thread, periodic scanner or per-frame event collection. World and player identities are
held through weak references.

### From reading to backup

The [WATCH](glossary.md#watch) stream carries life, character identity, death ID, sleep
and an optional report on the last save, over the existing authenticated connection.
Its message format is listed in the
[compatibility table](save-bridge.md#compatibility-and-lifecycle). The state
[reactor](glossary.md#collector-reactor-projection-outbox) commits the change and its
outbox entry together, and scheduling consumes them in the same transaction.

Death work carries an exact process, world, character and death guard, which the game
checks again immediately before saving. The standard game save follows the same
[admission](glossary.md#admission) rule.

### Report on the last save

The shared protocol can keep one fixed report on the last provider request it
admitted: the requested provider, the provider actually used, `Running`, `Succeeded` or
`Failed`, a fallback or error code, the milliseconds spent preparing on the game thread
and the total elapsed milliseconds. It holds no world objects, no growing history, no
credentials and no free-form exception text.

The report travels on the same read-only stream. App.Core builds a view of a fresh
report for the current process and world; WinUI only draws that view.

- The preferred provider and the actual outcome are shown separately.
- An old success does not switch on a disabled toggle.
- A fallback is shown as standard saving, not as a success of an extension.
- A report that is stale, from a disconnected game or from another world is not shown
  as the current save.

The provider contract is kept for compatibility and for synthetic tests. No optional
save provider is shipped, and backups use the game's original save (see
[game extensions](game-extensions.md)). The report's timings describe the request; they
are not a frame-time profiler and do not show that the game runs faster.

## Verification

Tests use synthetic game JVMs and temporary SQLite databases and files, never the
user's game or saves. They cover:

- a death while the flag stored in the database still says alive
- a death while the game is paused
- replays and a replaced character
- a character already dead at first sight, and several local players
- the option switches
- pending work that survives a restart
- retiring old death commands
- showing real save outcomes

The installed B42.20 `GameWindow`, `PlayerDB`, `VehiclesDB2`, `ExceptionLogger` and
`IsoChunk` classes were read and transformed in memory, and all five passed ClassFile
structural verification. This does not run game code, attach to a live game, or show
that saving stays consistent and fast with real vehicles and mods.

Real gameplay, the drawn UI and restoring vehicles and items end to end need separate
acceptance testing. Use the test output for the commit being evaluated, not historical
suite counts.
