# Character recovery

[Documentation index](../README.md)

Character recovery heals the character of a single-player save by editing its record in `players.db`. A dead
character is also marked alive, and when their saved inventory is empty, their belongings are moved back from
their zombie or corpse in the world. This page covers how the edit is made, how the remains are identified,
how the files are replaced safely, and what each refusal means. The player's steps are in
[revive a character](../guides/revive-a-character.md).

| Code | Responsibility |
| --- | --- |
| [`CharacterRecoveryService`](../../src/PzTools.Zomboid.Recovery/CharacterRecoveryService.cs) | Preview, the edit, staging and publishing |
| [`PlayerHealthEditor`](../../src/PzTools.Zomboid.Recovery/PlayerHealthEditor.cs) | Byte-level healing of the player record |
| [`WorldRemainsRecovery`](../../src/PzTools.Zomboid.Recovery/WorldRemainsRecovery.cs), `RemainsReader`, `CorpseChunkReader`, `ZombieInventoryRecovery`, `WorldItemRegistry` | Finding remains, matching identity, moving items |
| [`SaveFileEditTransaction`](../../src/PzTools.Process.Hosting/SaveFileEditTransaction.cs) | Durable multi-file replacement and roll-forward |
| `PzTools.Zomboid.Recovery.Cli` | The worker process |
| `RecoveryStamp`, `LiveCharacter` (bridge) | Writing the identity stamp in the running game |

## When it can run

The save must be inactive. The game does not have to be closed: the main menu, or another save loaded, is
fine.

- **App.** **Heal character** is enabled only for the current version of the selected save, when its activity
  is fresh and `Inactive`, no other operation runs, and the state and backup projectors are healthy
  (`MainWindowShell.UpdateRevisionActions`). With the game running, activity comes from the live
  observation (`GameActivityLane`): the main menu, unloading, or another world loaded is `Inactive`; this save
  loaded is `Active` and the button's tooltip asks the player to quit. A stale observation is `Unknown`, which
  also disables the button. The app checks again after the confirmation.
- **Locks.** The app admits the operation through its in-app gates for the save and the repository; a taken gate
  ends it as `operation-busy`. The worker takes the `SaveWrite` and `RepositoryAccess` mutexes; a taken mutex
  ends it as `Busy` with no error code.
- **Worker.** A restore journal beside the save (`.<save>.pztools-restore.json`) refuses with
  `recovery-save-busy`. A pending file edit is rolled forward first (below). Then the worker opens
  `players.db` for read and write, sharing only delete. A game that has the save loaded holds the file, so the
  open fails with a sharing violation, reported as `recovery-save-busy`. That handle stays open until the edit
  is published, so the game cannot load the old database meanwhile. A non-empty `-wal`, `-journal` or `-shm`
  file refuses with `recovery-pending-journal`.

Recovery makes no backup of its own and does not touch existing backups.

## Flow

1. **Preview.** When the confirmation opens, `AppHost.PreviewCharacterRecoveryAsync` opens `players.db`
   read-only, without a lock, heals the chosen character in memory, and, for a dead character with an empty
   inventory, lists candidate remains. Nothing is changed.
2. **Confirmation.** With more than one character the dialog lists them and preselects a dead one; the remains
   are looked up again whenever the choice changes. Remains are offered most items first, then nearest,
   followed by **Revive without belongings**. The confirm button waits for the search.
3. **Worker.** `PzTools.Zomboid.Recovery.Cli --saves-root --save-id --repository [--player-id] [--remains]
   --run-index --telemetry-identity`. `--remains` is a candidate key, `none` (revive without belongings, also
   used when nothing was found), or absent (alive, carrying items, or the preview failed).
4. **Staging.** The worker copies `players.db` through its exclusive handle into
   `.<save>.pztools-staging-<guid>\` beside the save and works on the copy: `PRAGMA integrity_check`, a
   non-empty `networkPlayers` table refuses (`recovery-singleplayer-only`), the character is read and healed,
   remains are applied, and the healed blob must heal to the same bytes again (`recovery-validation-failed`).
   Then `UPDATE localPlayers SET data=…, isDead=0` with `journal_mode=DELETE` and `synchronous=FULL`, and a
   second integrity check.
5. **Publishing.** See [writing the changes](#writing-the-changes). The staging folder is deleted afterwards.

## Which character

`localPlayers` rows are read in id order.

| Rows | `--player-id` | Result |
| --- | --- | --- |
| None | Any | `recovery-no-character` |
| One | None | That row, whatever its id |
| Several (local split screen) | None | `recovery-ambiguous-character` |
| Any | Given, not present | `recovery-character-missing` (the save changed since the list) |

Only the chosen row is updated. An earlier character cannot be chosen: when a character dies and the player
starts a new one in the same world, the game gives the new one the lowest free id and writes over the dead
character's row.

## Healing

`PlayerHealthEditor.Heal` accepts only world version 249 and a blob it can walk to the last byte; anything
else is `recovery-unsupported-format`. It parses every field it passes, records edits as byte ranges, and
copies everything else verbatim, including inventory, mod data and unknown flags. It calls no game reset
method, since some of them also erase traits or exercise regularity.

| Region | Edit |
| --- | --- |
| Forced sleep | Woken, wake-up timer cleared |
| 24 stats | Set to their rested values (three to 1, one to 37, the rest to 0); fitness is kept |
| 17 body parts | Rewritten as clean: health 100, no wounds, infection, bandage, splint or embedded objects; the bandage, stitch and splint XP bytes are kept |
| Body damage | Infection cleared (`infectionTime` and mortality duration -1) |
| Thermoregulator | Core 37, skin and node values reset; clothing insulation and wind resistance kept |
| Other | On fire, medicine and sleeping-pill effects, infection-reducing medicine timer, time since last smoke, death drag-down, scheduled exercise stiffness, pending soreness cleared |
| Inventory and worn items | Wound and bandage models taken off (see below) |

The game draws a wound or a bandage as an invisible piece of clothing, `Base.Wound_*` or `Base.Bandage_*`.
It puts the model on and takes it off only when it sees a body part's state change during play
(`IsoGameCharacter.Bandages`). A body part healed in the file shows no such change. Without help, its
wound would stay on the character until the same wound came and went again. Recovery therefore removes
those items from the inventory and the worn list, and renumbers the worn and held item indices
([`RemainsFormat.RemoveBodyModels`](../../src/PzTools.Zomboid.Recovery/RemainsReader.cs)). The item types
come from the save's `WorldDictionary.bin`. A save without it keeps the models.

Kept: traits, XP and levels, recipes, read books and media, nutrition and weight, position, hours survived,
kills, exercise regularity and timestamps, cheat flags, crafting history. The edit is checked by reading hours
survived back from the result; a mismatch fails with a message that is not a `recovery-` code, so the worker
reports it as `recovery-unsupported-format`.

A living character is only healed, also with an empty inventory. A dead one is marked alive (`isDead=0`) and
healed. Traits, the environment or mod illnesses can bring symptoms back after loading.

## Getting a dead character's belongings back

Only a dead character whose saved inventory is empty gets belongings back. A populated inventory is never
merged or overwritten.

### Finding candidates

`WorldRemainsRecovery.ListAsync` (used by the preview) reads, sharing read, write and delete:

- `reanimated.bin`: the save's player zombies;
- every `map/<x>/<y>.bin` chunk whose bytes contain the character's name, exact death position or recovery
  id. This byte filter only skips chunks that cannot match; every hit is then parsed in full. Chunks are read
  eight at a time (930 chunks of a real save, freshly copied: 1.1 s; 5.3 s one at a time);
- `WorldDictionary.bin`, to resolve item types (read whole, sharing read only).

`CorpseChunkReader` parses a chunk by structure: header, length and CRC32, squares, objects, corpse lists, erosion data and tail. A byte sequence that looks like a corpse
inside a bag or a ground item is never taken for one. A CRC32 mismatch refuses with `recovery-invalid-chunk`;
a wrong length or a chunk version other than 249 with `recovery-unsupported-format`. A corpse record carrying multiplayer data refuses
with `recovery-singleplayer-only`; animal corpses are skipped.

### Matching

`CharacterIdentity.Matches` compares the dead player's record with each record, strongest evidence first:

| Rule | Applies to | Match |
| --- | --- | --- |
| Recovery id | Either side has `pztools.recovery.id` | Both have it and it is equal. If only one side has it, nothing weaker is tried. |
| Name | A corpse that was not a zombie, both named | Same sex, same name, same stable appearance. Position is not compared, so a moved corpse matches. |
| Death position | Otherwise (zombies, nameless records) | Same sex, distinctive appearance on both sides, the exact saved death position, and the full visual data except the rot stage and skin texture number |
| Lookalike | Zombies in `reanimated.bin`, only when no record matched above and neither side has a recovery id | Same sex, distinctive appearance on both sides, and the same lasting appearance (hair and skin colour, hair and beard style, body hair), wherever the zombie walked |

The game rewrites the rot stage and the skin texture number when the character rises; the skin number is
fitted to the shorter zombie skin list (a woman's human skin 4 becomes zombie skin 3). The player record keeps
no clothing, so two characters made from the same preset both match as lookalikes; the player chooses.
Corpses in map chunks are never matched by look, because every killed zombie leaves one and random zombies
share the game's few hair and skin colours. A zombie is never chosen for being near. An ID card is an ordinary
item and plays no part.

A candidate's key is `<relative path>|<record offset>|<SHA-256 of the file>`. Only `reanimated.bin` and
canonical `map/<x>/<y>.bin` paths are accepted in a key.

### Applying the choice

`FindAsync` opens the chosen file for read and write, sharing only delete, re-reads it, and refuses with
`recovery-remains-changed` if its hash differs, the record is not at that offset, or it no longer matches by
the rule that listed it. With no key it uses the only candidate, refuses several as
`recovery-inventory-ambiguous`, and none as `recovery-inventory-unavailable`.

- **Removing the remains.** From a chunk: the record, the corpse count, the chunk length and the CRC32 change.
  From `reanimated.bin`: the record and the zombie count. The result is parsed again before use. Other chunks,
  objects and zombies are not changed.
- **Moving the items** (`RemainsFormat.RestoreInventory`). Item groups are copied byte for byte: instance
  ids, stack counts, condition, nested containers, modded fields. Wound and bandage models
  (`Base.Wound_*`, `Base.Bandage_*`) are left out and worn-item indices remapped. Duplicate item ids refuse as
  `recovery-inventory-ambiguous`.
- **Hands.** The stamped hand-item ids put the same items back in the character's hands. Without them the hands
  stay empty; attached-slot data in the items is kept.

<a id="the-identity-stamp"></a>
## The identity stamp

The [game bridge](game-bridge.md) writes reserved keys into the living player's modData. The game copies
modData from the player to the corpse and to the zombie in memory, which is what lets the id find the remains
later.

| Key | Holds | Written |
| --- | --- | --- |
| `pztools.recovery.id` | A UUID for the character | By the observer, and before a backup's save |
| `pztools.recovery.primary` | Instance id of the primary-hand item, or -1 | Before a backup's save |
| `pztools.recovery.secondary` | Instance id of the secondary-hand item, or -1 | Before a backup's save |

- **Observer** (`LiveCharacter`, `RecoveryStamp.IdentityWriter`). While the state stream is connected and there
  is exactly one local player, a living player object not yet seen with a valid id is checked at most every
  2 s, and gets an id if it has none. After that the per-frame cost is one reference comparison. A new
  character has an id within seconds, without a save.
- **Before saving** (`RecoveryStamp.record`). Right before `GameWindow.save(true)` (or a save provider's
  `begin()`), the id is kept or created and the hand items recorded as they are at that save. Probe requests do
  not stamp.

A dead or missing player is not stamped, and an existing valid id is never replaced, though a valid id in a
non-canonical form is rewritten in canonical UUID form; an unreadable value is replaced by a new one. A failed observer write only leaves the id missing. A failed stamp before a save is
reported as `recovery-metadata-unavailable` in the save's detail; the save still runs.

Only player one (`IsoPlayer.getInstance()`) is stamped, and the observer reads the character only with one
local player. Split-screen characters therefore have no id and are matched by name, position or appearance. A
character who died before PZ Tools was watching the game has no id either.

<a id="writing-the-changes"></a>
## Writing the changes

| Edit | Publishing |
| --- | --- |
| `players.db` only (healing, or revival without belongings) | One `File.Replace` of the staged database over the original |
| `players.db` and one world file | `SaveFileEditTransaction.CommitAsync` |

The transaction uses a journal folder `.<save>.pztools-file-edit` beside the save:

1. Each new file is copied into the journal and flushed. A map path is stored under the SHA-256 of its name
   plus `.data`, so the journal stays flat.
2. `manifest.json` (version 2) lists each file with its hash before and after, written to `manifest.tmp`,
   flushed and renamed. The rename is the commit point; cancellation is honoured only before it.
3. Each file is installed by copying the payload to `install.tmp` and `File.Replace` over the original. The
   journal is then deleted.

If installing fails after the commit point, the journal stays and the worker reports `save-edit-pending`.
Roll-forward (`SaveFileEditTransaction.RecoverAsync`) runs at app start (`InterruptedOperationRecoveryService`)
and before a restore or a recovery of that save. It opens `players.db` exclusively as the game's lock, then
for each file: the "after" hash means installed, the "before" hash (with a journal payload that hashes to
"after") means install it, anything else is
`save-edit-conflict` and nothing is overwritten, since the game may have changed the file since. A backup of a
save with a pending journal refuses with `save-edit-pending`, and orphan cleanup leaves it alone.

Journal names are validated: at most 32 files, no duplicates, only plain file names or `map/<x>/<y>.bin`, no
reparse points anywhere on the path. Version 1 journals, with root-level files only, are still read. A save or
world file path that is, or sits under, a reparse point is refused as `recovery-linked-path`. The transaction's
own checks on the journal folder, payloads, manifest and `install.tmp` fail with `linked-save-edit-path` or
`invalid-save-edit-inventory` instead.

## Error codes

The worker's failure message is the code; `UserFacingErrorCatalog.FromProcessError` picks the message. An
`InvalidDataException` whose message is neither a `recovery-` nor a `save-edit-` code becomes
`recovery-unsupported-format`, and an `IOException` for a sharing or lock violation (Windows errors 32 and 33)
becomes `recovery-save-busy`. A bad option ends the worker with `invalid-arguments` and exit code 64, and a stop
request from the app (or Ctrl+C) with `Cancelled`; the edit honours it only before its commit point.

| Code | Cause | Message key |
| --- | --- | --- |
| `recovery-save-busy` | Another process (usually the game) holds `players.db` (sharing or lock violation), or a restore journal exists | `RecoveryError.Busy` |
| `recovery-pending-journal` | A non-empty SQLite journal beside `players.db` | `RecoveryError.Journal` |
| `recovery-singleplayer-only` | A `Multiplayer` save, network players, a networked corpse, a malformed save id | `RecoveryError.Ambiguous` |
| `recovery-ambiguous-character` | Several characters and none chosen | `RecoveryError.CharacterNotChosen` |
| `recovery-character-missing` | The chosen character is gone | `RecoveryError.CharacterChanged` |
| `recovery-remains-changed` | The chosen remains changed since the list | `RecoveryError.RemainsChanged` |
| `recovery-inventory-unavailable`, `recovery-inventory-ambiguous` | No remains, several without a choice, or duplicate item ids | `RecoveryError.Inventory` |
| `recovery-unsupported-format`, `recovery-invalid-chunk`, `recovery-unsupported-dictionary`, `recovery-invalid-database`, `recovery-no-character`, `recovery-validation-failed`, `recovery-linked-path` | The save is not in the supported format, is damaged, or is linked | `RecoveryError.Unsupported` |
| `save-edit-pending`, `save-edit-pending-database-journal`, `save-edit-conflict`, `save-edit-invalid-journal` | An earlier edit is unfinished | `RecoveryError.PendingEdit` |

Errors with no code (a SQLite error such as a file that is not a database, or `linked-save-edit-path`) show the
generic error message. Another PZ Tools operation on the save never reaches the worker: the app reports
`operation-busy`, and a worker that finds a mutex taken ends `Busy`.

Every refusal before publishing leaves this edit unwritten. An earlier pending edit that the worker rolled
forward first stays installed.

## Limits

- **One format.** Only world version 249, checked against the 42.20.4 game classes and the MIT-licensed
  [pzdataspec world 249](https://github.com/cff29546/pzdataspec/tree/main/data_spec/spec/249) schemas
  ([third-party notices](../../THIRD_PARTY_NOTICES.md)). No game classes or third-party parser are shipped.
- **Lost items stay lost.** Items dropped elsewhere, looted or destroyed are not recreated.
- **Old deaths.** A zombie with no recovery id that has walked away may not be identifiable; updating PZ Tools
  cannot mark it afterwards. Saves without hand-item ids need items re-equipped by hand.
- **No new thumbnail.** `thumb.png` is not regenerated.
- **Not tried in the real game.** Automated tests do not load an edited save in the game. Visual equipment,
  future formats and unusual mod serialisation need separate acceptance.

## Tests

[`CharacterRecoveryTests`](../../tests/PzTools.Backup.Tests/CharacterRecoveryTests.cs),
[`CorpseResurrectionTests`](../../tests/PzTools.Backup.Tests/CorpseResurrectionTests.cs) and
[`SaveFileEditTransactionTests`](../../tests/PzTools.Backup.Tests/SaveFileEditTransactionTests.cs) cover
healing that keeps traits and unknown mod data, character choice, remains matching (moved and renumbered
zombies, lookalikes, decoy bytes), byte-exact item moves, malformed and truncated data, failure leaving the
original unchanged, and interrupted publication. They check behaviour and bytes on temporary copies, never
the user's saves.
