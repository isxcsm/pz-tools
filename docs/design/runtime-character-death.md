# Character death

[Documentation index](../README.md)

When the played character dies, periodic backups wait for a new life, so backups of the dead character do not
push the backups made while it was alive out of the kept number ([retention](glossary.md#retention)). With
**Back up when the character dies** on, one backup is made of the moment of death. Both decisions use the
character's life as read live from the game through the [game bridge](game-bridge.md), never the `isDead`
flag in `players.db`. What the player sees is in
[backups](../reference/backups.md#when-the-character-dies).

## Reading life and death

`LiveCharacter` reads the character on the game thread each frame, as part of the
[state observer](runtime-pause-backups.md#reading-the-game). It reads only when the world is ready in local
single player and `IsoPlayer.numPlayers` is 1; otherwise life is `Unknown`. `IsoPlayer.getInstance()` and
`isDead()` give `Alive` or `Dead`; a failed read is `Unknown`, never alive or dead.

`RuntimeCharacterIdentity` (in the extension API, so it survives a payload reload) turns those readings into
identities:

| Event | Character id | Death id |
| --- | --- | --- |
| A new player object (new character, a loaded save, a revived character in a reloaded save) | New | None |
| A new world | Cleared; the next player gets a new id | None |
| `Alive` followed by `Dead` for the same player object | Same | New |
| `Dead` at the first reading of a player object, or after `Unknown` | Same | Kept as it was (none for a new object) |
| `Dead` followed by `Alive` (revived in the running game) | Same | Cleared |
| The state stream ends | Same | Kept; the next reading starts from `Unknown` |

Only a change from `Alive` to `Dead` that the observer sees makes a death id. So:

- A character already dead when first seen, or seen dead again after a reconnect, is not a new death.
- A death that happens while the stream is disconnected gets no death id and no death backup. Periodic
  backups still wait, as the character reads `Dead`.
- A character brought back to life, by the game or by [character recovery](character-recovery.md), is alive
  again. Its next death is a new death with a new id.

Ids are random 32-hex-digit values held with weak references to the player and world objects; they are not
stored in the save.

The `STATE` frame carries life, character id, death id and sleep. `RuntimeSnapshot.Validate` rejects a death
id without `Dead`, and any life other than `Unknown` without a ready world and a character id.

## Waiting for a new life

`RuntimeObservation.IsCharacterDead` is true for a fresh observation of a ready world whose character is
`Dead`.

| Scheduling | Gate |
| --- | --- |
| Game-aware | `ActiveTimeSchedulePolicy.Advance` adds the `CharacterDead` hold and sets the remaining time to a full interval while dead. The schedule line shows **Character dead – backups waiting**. |
| Wall-clock, and the link fallback | `BackupScheduler.WaitsForNewCharacter` keeps a due periodic backup waiting while the dead character's save is the backup's target. It runs once the character is alive. |

When the character is alive again, by a new character or a revival, the hold lifts. Under game-aware timing
the countdown starts from a full interval, since the time spent dead was not counted. The gate needs a fresh
observation: while the game cannot be read, the fallback backs up whatever is on disk.

The gate applies whether or not the death option is on.

## The death backup

1. `StateOutboxRelay` relays each committed observation with `backupOnDeath` read from the state-reactor's
   configuration (`[state].backup_on_death`, which the app fills from its `[backup].backup_on_death`).
2. `SchedulerDatabase.ApplyDeathAsync` builds the event key
   `runtime-death:<process>:<world>:<character>:<death>` (`RuntimeDeathPolicy.EventKey`) for a fresh
   observation of a dead character with a death id. If it equals the stored `runtime_death_cursor`, nothing
   happens. Otherwise the cursor moves to it, even when the option or automatic backups are off, so switching
   the option on later does not replay an old death.
3. If the option is on, automatic backups are on and the save resolves to a target, it queues one `RunOnce`
   pending run with the event key as its id, in the same transaction.
4. `PrepareBackupTickCore` takes the first pending run. For a death run it builds a death ticket from the
   current `runtime_facts` (`ReadDeathTicketAsync`). If the facts no longer show this exact death on this save
   (stale, alive again, another character, another world), the run is deleted. Otherwise it waits until
   1 s after it was queued (`RuntimeDeathPolicy.Settle`), so the game has finished the death first.
5. `RuntimeScheduleController.PrepareAsync` admits it only while the live observation still matches the
   ticket (`RuntimeSaveTicket.MatchesDeath`) and the save path. The pause hold and the periodic countdown do
   not apply.
6. The worker runs as a guarded backup. The game checks the ticket every frame until the save starts:
   same process, observer and world, world ready in local single player, the character still `Dead` with the same character and death id
   (`runtime-character-changed` otherwise). Pause, sleep and the active clock are not checked. The countdown
   notice is skipped because the ticket is due at once.

`RuntimePreparationPermit` checks, before and during the request, that automatic backups and the death option
are still on and that the facts still show this death.

A death backup is an ordinary automatic backup once made: it is retained like the others. **Save game before
backup** and the countdown setting apply as for any guarded backup, and an unreachable game gives a backup of
the files on disk ([outcomes](game-bridge.md#admission-and-failures)).

### One death, at most one backup

| Situation | Result |
| --- | --- |
| The worker started and the backup succeeded, failed or its outcome is unknown | The pending run is deleted; it is not replayed |
| The worker reported `Skipped` (deferred before the save started) | The pending run stays and is tried again while the death is current |
| The worker never started | The attempt counter goes up and the run stays |
| The target changes (another save, main menu, the game exits) | All pending runs are deleted with the target switch |
| Automatic backups are switched off | All pending runs are deleted |

Pending runs live in `scheduler.db`, so a pending death backup survives a scheduler restart, and is still
dropped at step 4 if the death is no longer current.

## The save database is separate

`CharacterState` in the save discovery pipeline describes what `players.db` stores, for the save list. It is
never overwritten by a live reading, has no death option and emits no death commands. `RunOnceNow` commands
that older versions derived from `players.db` transitions are acknowledged and dropped by the relay rather
than replayed.

## Limits

- **Sampled, not logged.** Life is read each frame while the stream is connected; it is not a record of game
  events. A death while disconnected is not a death event.
- **Single player, one local player.** Split screen reads as `Unknown`: no death backups, no dead hold.
- **No fallback to the save files.** Without a live reading, PZ Tools never decides about a death from
  `players.db`.
- **A reading is not a save.** Seeing the death does not mean the game has written it to disk; the death
  backup asks the game to save first.

## Tests

[`RuntimeDeathPolicyTests`](../../tests/PzTools.Backup.Tests/RuntimeDeathPolicyTests.cs) covers a death
while paused, one death not replaying, the dead hold and the full interval of a new life, the wall-clock gate,
deaths consumed while the option is off, and a new character invalidating a pending death backup. The bridge
tests drive life and death in a synthetic game JVM. Tests use temporary databases, never the user's game or
saves; real gameplay needs separate acceptance testing.
