# Offline character recovery

The current-save row exposes a confirmation-gated heal/resurrect action. Revisions are never
edited. The UI requires a fresh, inactive save; the worker additionally holds a non-sharing
read/write handle on `players.db`. Opening that handle fails if the game is using the DB.
Repository/save operation mutexes serialize recovery with backup, restore and deletion.

## Supported format and limits

The binary layout was checked against the installed Project Zomboid 42.20.4 Java bytecode,
world version **249** (`Stats`, `BodyDamage`, `Fitness`, `IsoGameCharacter`, `IsoPlayer`).
Only one local player, ID 1, is accepted. Multiplayer, multiple local players, other world
versions, malformed data, symlinks/reparse points and nonempty SQLite sidecars are rejected.
Every edited boundary and the complete tail are parsed before writing. This is not a
general promise of compatibility with future versions or mods that replace serialization.

The editor restores health, food, thirst, fatigue, endurance, morale and sanity; clears
anger, boredom, discomfort, sickness, panic, pain, poison, intoxication, infection, fever,
stress, nicotine withdrawal and idleness. All 17 body parts are healed, including embedded
glass/bullets, fractures, burns, wounds, infection flags and timers. Core temperature is
37 C and metabolic rate 1.5 (the game's default, shown as 50%). Pending exercise soreness,
fire, forced sleep, drug-effect timers and the death-drag-down flag are cleared.

The trait/XP block is copied **byte for byte**, including every negative trait. Fitness,
weight/nutrition, skills, recipes, appearance, inventory, location, survival time, exercise
regularity and exercise history are preserved. Mod data is opaque and preserved; unrecognized
mod-specific conditions cannot be promised cured. Negative traits, wet clothing or the
environment can immediately cause symptoms again. This is healing, not permanent immunity.

Resurrection clears `localPlayers.isDead` together with healing the blob. When the player
inventory is empty, the worker parses world-249 `reanimated.bin` records and the authoritative
`WorldDictionary.bin` item registry. A donor must have the identical saved x/y/z and exactly
one ID card whose parsed custom name ends with `: <full character name>`. Multiple matches,
unknown formats, or an unidentifiable empty-inventory dead character abort before publication.
This deliberately does not guess from proximity, appearance or a nearest corpse. A moved
zombie, missing ID card, or a corpse stored in map chunks is not supported by this first path.

Normal item groups are copied verbatim, including instance IDs, condition, custom/mod data
and nested bag contents. Only vanilla `Base.Wound_*` overlays are excluded. Worn indexes are
remapped after filtering; hands are cleared because zombies do not retain reliable hand
references. The matching zombie record is removed; all other records stay byte-identical.
An already-healed, empty-inventory character can use the same strict match. A populated
player inventory is never overwritten or merged. The preview is not regenerated offline.

## Transaction

Health-only edits change `players.db`. Inventory recovery also changes `reanimated.bin`.
Preparation uses a sibling staging directory excluded from save
discovery. SQLite integrity checks, a transaction and an idempotent re-parse validate the
staged result before publication. Recovery does not create an additional backup or
retain a copy of the original DB. Save history is managed by the existing backup system.
The temporary working directory is removed when the operation finishes.

For the two-file edit, `SaveFileEditTransaction` durably prepares replacement payloads and
before/after hashes in a sibling `.pztools-file-edit` directory, then publishes a manifest
before replacing either original. Cancellation is honored before this decision, not between
replacements. A failure after publication starts retains the pending payloads. Startup and
maintenance recovery finish the edit under the save-write lock; backup is blocked while it
is pending. Recovery first validates every current file against its before/after hash and
refuses to overwrite changes made by the game after an interruption. Do not load a partially
updated save before this recovery runs. Completed operations remove all temporary payloads;
they are not retained user backups and are outside the save/backup source tree.

## Tests

`CharacterRecoveryTests` covers byte-exact trait/progress preservation, injuries and latent
soreness, stat values, idempotence, unsupported/truncated layouts, resurrection without extra
copies, active-file locks, pending journals and ambiguous characters. Inventory tests cover
identity/position mismatch, multiple donors, opaque item bytes, worn remapping, wound filtering,
other-zombie preservation and truncated input. Transaction tests cover partial publication,
startup replay, interrupted cleanup, cancellation, payload corruption and post-crash conflicts.
For local validation,
`PZTOOLS_RECOVERY_SAMPLES` may contain semicolon-separated DB paths: inputs are opened read-only
and all service edits use isolated temporary copies. `PZTOOLS_RECOVERY_ZOMBIE_SAMPLE` accepts
the investigated dead-character save directory for the optional seven-item integration check.
No private game blobs are checked in.
