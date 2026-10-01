# Character recovery

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

Character recovery heals the character in a single-player save while the game is
closed. If the character has died, it also brings them back to life and, when their
belongings were left on their body or on the zombie they turned into, puts those
belongings back in their inventory. It is for players who want to carry on with a
character. This page explains what it changes, what it keeps, and when it cannot help.

## Before you start

1. Stop playing the save. Recovery needs an up-to-date
   [observation](glossary.md#observation-fresh-stale) that the save is not in use.
2. Make a backup first. Recovery edits the current save once you confirm. It does not
   edit existing backups and does not create an extra backup for you.

## What healing does

| Effect | What |
| --- | --- |
| **Restored** | Health, food, thirst, fatigue, endurance, mental condition, and all 17 body parts, including injuries, infection and embedded glass or bullets. Core temperature and metabolic values go back to their defaults. |
| **Cleared** | Temporary illness, poisoning, withdrawal, pending exercise soreness, burning, forced sleep and the death drag-down flag |
| **Kept** | All positive and negative traits, XP, skills, recipes, nutrition and weight, position, survival time and exercise history. Unrelated mod data is copied unchanged. |

A character who has died is marked alive again. A living character is simply healed,
also when their inventory is empty.

Symptoms can come back afterwards because of traits, the environment or illnesses
added by mods.

## Which character

A single-player save normally holds one character, and that one is recovered whatever
its number in `players.db`. The game numbers characters from 1, but a save whose
character is not number 1 is just as valid (v0.1.0 refused such saves).

Several characters appear only with local split screen. The confirmation then lists
them, with name, whether they are dead and how long they survived, and recovers only
the one you choose; the others are left exactly as they are. If the chosen character is
no longer there when recovery starts (the save changed in between), nothing is edited.

An earlier character cannot be chosen. When a character dies and you start a new one in
the same world, the game writes the new character over the dead one's record, so the
earlier character is no longer in the save to bring back.

## Getting a dead character's belongings back

This happens only when the dead character's saved inventory is empty. A populated
inventory is never merged with or overwritten by recovered items.

Recovery looks for the character's remains in two places: zombies in `reanimated.bin`,
and the corpse lists in the world's `map/<chunk-x>/<chunk-y>.bin` files. Item types are
resolved through `WorldDictionary.bin`. An ID card is treated as an ordinary item; it
is not needed to identify the character.

### Choosing in the confirmation

The search runs when the confirmation opens, before anything is changed, and the
confirm button waits for it (well under a second on a warm disk; a freshly copied save
of 930 map files took 1.1 s). What it finds is shown in the confirmation:

- **Remains found:** each one is listed as a zombie or a corpse, with how many items it
  carries and how far it is from where the character died. The one carrying most is
  chosen; you can pick another, or **Revive without belongings**. The remains you
  choose are removed from the world; the others are left as they are.
- **Nothing found:** the confirmation says so, and the character is revived without
  belongings rather than not at all.
- **The search failed:** the confirmation says so, and recovery looks again on its own.

Recovery then edits only the remains you chose. It reads only that file again, and
refuses with `recovery-remains-changed` if the file is no longer exactly as it was
when the list was made. Without a choice (the worker run directly), the only candidate
is used; several are refused as ambiguous and none as `recovery-inventory-unavailable`.

### How the remains are identified

Four kinds of evidence are used, strongest first:

1. **Recovery ID.** A saved `pztools.recovery.id` UUID matches the player to the
   remains, even if the zombie has wandered off or the body's appearance has changed.
   If one side has a conflicting or missing UUID, weaker matching is not tried
   instead. If several remains match, recovery stops.
2. **Named corpse.** Older player corpses that still carry a name can match on the
   saved name, sex and persistent appearance fields. Such a corpse can be matched even
   if it was moved from where the character died.
3. **Nameless zombie.** Older reanimated records lose their name. They need
   distinctive full visual data inherited from the character, the same sex, and the
   exact saved death position. Two visual fields are ignored because the game rewrites
   them when the character rises: the rot stage, and the skin texture number, which
   the game fits to the shorter list of zombie skins (a woman's human skin 4 becomes
   zombie skin 3).
4. **Lookalike player zombie.** Only when rules 1–3 find nothing, and neither side has a
   recovery ID: a zombie in `reanimated.bin` with the same sex and the same lasting
   appearance (hair and skin colour, hair and beard style, body hair), wherever it has
   walked. The game keeps only the save's player zombies in that file, so the
   candidates are the world's earlier characters. The dead player's record keeps no
   clothing, so two characters made from the same preset both match; that is why the
   user chooses. Corpses in map chunks are never matched this way: every killed zombie
   leaves one there, and random zombies share the game's few hair and skin colours.

A character who died while PZ Tools was not connected to the game (before it was
installed, or with versions up to v0.1.0, which stamped only at a backup) has no
recovery ID, so their remains are found by rules 2 to 4.

A zombie is never chosen just because it is nearby.

### What is copied

- Opaque item groups, instance IDs, stack counts, condition, the contents of bags
  inside bags, and modded item fields are copied byte for byte.
- Vanilla wound-overlay items are left out, and the indices of worn items are remapped.
- Metadata of items in attached slots and the original hotbar data are kept.
- Saved hand-item IDs put the exact recovered items back in the character's hands,
  when they are available.

## Limits

- **One game format.** Only Build 42 world version **249** is supported. It is checked
  against the locally installed 42.20.4 game classes and the MIT-licensed pzdataspec
  world-249 schemas.
- **Refused before any edit:** other versions, several local characters with none
  chosen, a chosen character that is gone, chosen remains that changed since the list,
  network players, malformed records, linked paths and pending SQLite journals.
- **Lost items stay lost.** Items that are missing, were dropped elsewhere, looted or
  destroyed are not recreated.
- **Old saves.** Saves made without hand-item IDs need the items re-equipped by hand.
  A zombie from an older save with no recovery ID that has already wandered away may
  not be identifiable. Updating PZ Tools cannot mark such a zombie after the fact.
- **No new thumbnail.** Recovery does not regenerate `thumb.png`.
- **Not tried in the real game.** Automated tests do not load an edited save in the
  actual game. Visual equipment behaviour, future formats and unsupported mod
  serialization still need separate acceptance (see [verification](#verification)).

## How it works inside

### Keeping other jobs out

The worker takes the save-operation mutex and opens `players.db` exclusively, allowing
only deletion (so the file can be replaced atomically). Repository and save mutexes
prevent recovery, backup and restore from changing the same data at the same time.

Parsing checks complete record boundaries. No game classes, private save data or
third-party runtime parser are distributed with PZ Tools.

### Reading map files

Map files are parsed by their structure, not searched for isolated byte patterns.

- A first filter on name, position and UUID may skip a chunk that cannot contain a
  match. Every hit must then pass the structural chunk parser and the length and CRC32
  checks.
- The parser walks through tiles, erosion data, length-delimited object data, corpse
  lists and the chunk tail. A byte sequence that looks like a corpse inside a bag or a
  ground item is therefore not taken for a corpse.
- Removing the remains changes only the selected record, the list's count and the
  chunk's length and checksum. Other chunks, objects and zombies are left unchanged.

### The identity stamp on future saves

To make later recoveries reliable, the [save bridge](save-bridge.md) writes three
reserved keys into the player's modData on the game thread:

| Key | Holds |
| --- | --- |
| `pztools.recovery.id` | A stable ID for the character |
| `pztools.recovery.primary` | The instance ID of the item in the primary hand |
| `pztools.recovery.secondary` | The instance ID of the item in the secondary hand |

They are written at two moments:

- **While the game is being watched.** The runtime observer, which already reads the
  character each frame for the game-link status, looks at a living player it has not
  yet seen with an ID, at most every two seconds, and writes one if there is none. Once
  that player has an ID it is not looked at again. A new character therefore has an ID
  within seconds, long before a death is likely, and no save is needed: the game
  copies the player's modData to the corpse and the zombie in memory. Hand items are
  not written here.
- **Immediately before a backup's `GameWindow.save(true)`.** The ID is kept (or created)
  and the hand items are recorded, as they are at that save.

The hand keys store item instance IDs, not item types or ordinals. The game carries
modData over when a player becomes a corpse or a zombie, which is what lets the ID
find the remains later. When there is no player, or the player is dead, nothing is
written, so no new identity is created; an existing ID is never replaced.

The stamp is optional metadata. If the observer's write fails, only the ID is missing.
If stamping before a save fails, the bridge result reports
`recovery-metadata-unavailable`, but `save(true)` still runs and backup capture still
waits for it to finish. Probe-only requests do not stamp. The stamp adds no timer,
thread or JVM retransformation of its own; once the player has an ID, the observer's
check is one reference comparison per frame, and the game methods it needs are looked
up once. Characters that were never stamped keep using the stricter rules for older
remains described above.

### Writing the changes

All preparation, and the SQL integrity and idempotence checks, run on a staging copy.

- **Healing only** (including revival without inventory recovery) replaces
  `players.db` alone, in one atomic file replacement.
- **Inventory recovery** also replaces one reanimated file or one map chunk. All
  replacement bytes and before/after hashes are written durably first; then a commit
  manifest is published.

Cancellation is honoured until that commit decision. If publishing is interrupted
after it, a roll-forward journal is left for recovery at startup. That recovery checks
every current file against the journal's hashes and refuses to overwrite changes the
game has made since. Do not load the save while such a journal is pending.

Journal version 2 adds canonical nested map paths while keeping the payload files in a
flat folder. Pending version 1 journals, which have root-level files only, can still be
read. Path traversal, alternate data streams, non-canonical chunk paths, reparse-point
parent folders and colliding payload names are rejected. The guards on the original
files stay held through publication.

When recovery completes, its staging and journal files are removed. No extra permanent
backup is kept, and existing backup history is not touched.

## Verification

Focused Windows tests cover:

- health and traits
- a lone character that is not number 1, choosing one of two characters, and a chosen
  character that is gone
- inventory recovery without an ID card
- stamped zombies that have moved
- a nameless zombie whose skin texture number the game changed
- a lookalike player zombie that walked away, a choice between two lookalikes, proven
  remains hiding lookalikes, killed-zombie corpses never matched by look, chosen
  remains that changed since, and reviving without belongings
- hand-item IDs
- named corpses
- byte-exact bags and items
- duplicate identities
- corpse-like decoy data embedded in opaque data
- CRC errors and truncation
- repeated recovery
- path confinement
- interrupted publication of a chunk together with the player

The tests check behaviour and bytes, not how the source code is spelled. The synthetic
Java game checks that a stable stamp is written by two required saves. The existing
save, backup, restore, cancellation and failure tests remain.

Copy-only checks also used real-save samples and an adapted corpse fixture. None of
this loaded an edited save in the actual game. Visual equipment behaviour, future
formats and unsupported mod serialization still need separate acceptance.

Reference schemas: [pzdataspec world 249](https://github.com/cff29546/pzdataspec/tree/main/data_spec/spec/249).
See [third-party notices](../THIRD_PARTY_NOTICES.md) for attribution.
