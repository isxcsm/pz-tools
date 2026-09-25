# Offline character recovery

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Recovery edits only the current single-player save after confirmation. Backup revisions
are not edited. The UI requires a fresh inactive save; the worker also takes the save
operation mutex and an exclusive, delete-sharing players.db handle. The game must not
be using the save. Repository/save mutexes serialize recovery with backup and restore.

## Health and saved progress

Supported serialization is Build 42 world version **249**, checked against the locally
installed 42.20.4 classes and the MIT pzdataspec world-249 schemas. Other versions,
multiple local characters, network players, malformed records, linked paths and pending
SQLite journals are rejected before editing. Parsing covers complete record boundaries.
No game classes, private save data or third-party runtime parser are distributed.

Existing healing restores health, food, thirst, fatigue, endurance, mental condition
and all 17 body parts, including injuries, infection and embedded glass/bullets. It
clears temporary illness, poisoning, withdrawal, pending exercise soreness, burning,
forced sleep and the death-drag-down flag. Core temperature and metabolic defaults are
restored. All positive/negative traits, XP, skills, recipes, nutrition/weight, position,
survival time and exercise history remain. Unrelated mod data is copied unchanged.
Traits/environment/mod-specific illnesses can cause symptoms again; this is not immunity.

## Belongings from a zombie or corpse — no ID-card dependency

When a dead player's saved inventory is empty, inspect both `reanimated.bin` and the
world's `map/<chunk-x>/<chunk-y>.bin` corpse lists. The authoritative WorldDictionary.bin
resolves item types. An ID card is treated as an ordinary item, never as an identity key.

Identification uses these explicit evidence levels:

1. A saved `pztools.recovery.id` UUID matches the player to remains, even if the zombie
   wandered or the body's appearance changed. Conflicting/missing UUIDs on one side do
   not fall back to weaker matching. Multiple matching remains abort the operation.
2. Older named player corpses can match the saved name, sex and persistent appearance
   fields. A corpse can therefore be moved without relying on its death coordinates.
3. Older reanimated records lose their names. These require distinctive inherited full
   visual data (ignoring only zombie rot stage), sex and the exact saved death position.
   An already-wandered legacy zombie with no UUID may still be unidentifiable. The tool
   refuses to select the nearest zombie or invent evidence in that case.

Map files are not byte-carved. A cheap negative name/position/UUID filter may skip a
chunk with no possible match; positive hits must pass the structural chunk parser,
length and CRC32 checks. It traverses tiles, erosion, length-delimited object data,
corpse lists and the chunk tail. A corpse-looking byte sequence inside a bag or ground
item is not a corpse. Removal changes only the selected record, its list count and
chunk length/checksum. Other chunks, objects and zombies are left unchanged.

Opaque item groups, instance IDs, stack multiplicity, condition, nested bag contents and modded
item fields are copied byte-for-byte. Vanilla wound-overlay items are omitted and worn
indices are remapped. Attached-slot item metadata and the original hotbar data remain.
Saved hand-item IDs restore the exact recovered items when available; an item that is
missing, dropped elsewhere, looted or destroyed is not guessed or generated. Old saves
without those hand IDs still need manual re-equipping. A populated player inventory is
not merged/overwritten. Living characters with an empty inventory can still be healed.
The offline operation does not regenerate thumb.png.

## Stable identity on future saves

Immediately before the existing game-thread `GameWindow.save(true)`, the bridge records
only three reserved keys in that player's modData: `pztools.recovery.id`,
`pztools.recovery.primary`, and `pztools.recovery.secondary`. The game copies modData
through its corpse/reanimation path. The ID stays stable; primary/secondary store item
instance IDs, not types or ordinals. Dead/no-player probes do not create new identities.

This step is optional metadata, not a replacement for the mandatory save. A reflection
or stamping failure is reported in the bridge result as `recovery-metadata-unavailable`,
but `save(true)` still runs and its completion is still required before backup capture.
Probe-only requests do not stamp. No new timer, game loop hook, thread or repeated JVM
retransformation is added. Existing unstamped saves continue to use the strict legacy
criteria above; updating the app cannot retroactively mark an already-wandered zombie.

## Multi-file transaction

Preparation and SQL integrity/idempotence checks occur on a staging copy. Health-only
recovery replaces players.db; inventory recovery also replaces one reanimated file or
one map chunk. All replacement bytes and before/after hashes are made durable before
a commit manifest is published. Cancellation is honored before that decision; after
it, interrupted publication leaves a roll-forward journal, not a half-deleted inventory.
Startup recovery verifies every current file against the journal hashes and refuses to
overwrite subsequent game edits. Do not load the save while such a journal is pending.

Journal version 2 adds canonical nested map targets while keeping payload files flat.
Version 1 root-only pending journals remain readable. Traversal, alternate data streams,
noncanonical chunk paths, reparse parents and colliding payload names are rejected.
Original-file guards remain held through publication. Successful completion removes
staging/journal files; it does not retain an extra permanent backup. Existing backup
history is untouched, and keeping a known-good backup before destructive recovery is
still appropriate.

## Verification scope

Focused Windows tests cover health/traits, no-ID-card inventory, moved stamped zombies,
hand IDs, named corpses, byte-exact bags/items, duplicate identities, opaque embedded
corpse decoys, CRC/truncation, repeat recovery, path confinement and interrupted
chunk+player publication. Tests exercise behavior and bytes, not source-code spelling.
The synthetic Java game verifies a stable stamp is written by two required saves;
existing save/backup/restore, cancellation and failure tests remain.

Local research parsed all 572 chunks from a dead-character save and all 5,095 chunks
from another save with zero parser failures. Copy-only acceptance recovered the dead
save as-is (7 ordinary items, 5 worn slots) and with its ID card removed (6 ordinary
items, 5 worn slots). A third fixture transplanted that copied no-card inventory into
a corpse within a **copy of a real surrounding chunk** and recovered the same 6 items.
Opaque item bytes remained exact; other chunk bytes matched the expected single-record
removal. All 743 original dead-save files passed before/after SHA-256 comparison.

That third case is an adapted fixture, not an observed real player-corpse gameplay
session. No edited save was loaded in the actual game, no real player was revived in
place, and no user files are checked into Git. Actual-game visual equipment behavior,
future formats and unsupported mod serialization are not claimed verified.

Reference schemas: [pzdataspec world 249](https://github.com/cff29546/pzdataspec/tree/main/data_spec/spec/249).
See [third-party notices](../THIRD_PARTY_NOTICES.md) for attribution.
