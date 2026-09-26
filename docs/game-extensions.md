# Game extensions and private backup saving

[Documentation index](README.md) · [Save bridge](save-bridge.md) · [Live character state](runtime-character-death.md)

## Current scope

Seamless Saving **0.7.0**, bootstrap API **7**, save protocol **6**.
Replace app/worker/JARs together and restart the entire game. In particular, an older
bootstrap already containing the retired global hooks cannot be upgraded just by toggling
the extension. No backup-repository reset is needed.

This remains experimental low-interruption saving, not a zero-stall or atomic world
snapshot guarantee. The public game save implementation is preserved. The extension
now uses an explicit private, versioned entry rather than intercepting ordinary saves.

## Separate entry points

```text
Standard provider / game / other mod -> original GameWindow.save(true)
Our selected extension             -> VersionedSaveEntry.saveForBackup()
                                  -> private GameWindow / IsoCell / ChunkMap / Chunk bodies
                                  -> original serializers, native saving and guarded chunk I/O
```

`PrivateSaveGraph` builds four hidden nestmate companions from the inspected game
method bodies. Only their internal call sites use private handles. The game classes
are not replaced and receive no added save methods or fields. Their original save,
read, write, thumbnail and native-stop implementations remain installed unchanged.
Companions are generated in the target JVM; no game classes or copied game code are
redistributed in our JARs.

Only the private root omits its own preview. A nested `OnSave` handler calling the
original `GameWindow.save` still gets the normal preview and normal I/O. Virtual calls
on modded subclasses use the original virtual method instead of bypassing its override.
The original full-save coverage, including chunk serialization's vehicle effects,
player/virtual vehicles, animals, native systems and Lua events, is not reduced.

A read-only transformer inspects the live source methods and returns null for them.
Canonical method fingerprints detect relevant changes by other transformers; a changed
source disables new private captures. The normal provider remains the pre-capture fallback.
No automatic replay occurs after a private capture starts. Later third-party agents
can still interfere with a shared JVM; this is not an arbitrary-mod compatibility guarantee.

## Ordered I/O without changing normal readers or writers

The private chunk path copies serialized bytes and reserves the game's counted per-file
lock. One worker acquires that original write lock, opens the existing file without
truncation, then acknowledges the handoff. Only then may the game continue. The worker
writes the detached bytes, closes the channel, unlocks on the SAME worker thread, and
releases the counted reference. Normal unmodified reads/writes use this same game lock.
They cannot read half a file or let a later write be overwritten by the older private write.
The opened channel pins the file; renaming after handoff does not redirect the write.

There is one I/O worker, at most two retained operations, and a 64 MiB copy budget.
New files, unsupported buffers and unavailable capacity use the original synchronous
SafeWrite before any handoff is accepted. No chunk is omitted. World exit/cancellation
does not discard accepted writes or report completion before resource release.

The handoff can wait for a competing lock or the previous I/O. Native saving, including
its completion wait, is synchronous again. This is deliberate: returning early from
shared native writes required modifying ordinary save/stop paths to remain safe.

The previous FileWriteHooks/SaveWaitHooks, public SafeRead read-through, JDK-internal
file-key adapter, auxiliary-output rewrites and native save/stop rewrites were removed.
They are not hidden fallback modes. Some earlier optimizations are consequently no
longer active; no performance improvement over 0.6 is asserted without measurements.

## Observation and ownership

The existing game-loop dispatch and WATCH session still supply pause, version, live
character/death and execution status. Saved players.db state stays independent.
Three narrow read-only observers remain: PlayerDB/VehicleDB drain enter/exit and
ExceptionLogger errors. They do not replace serializers, swallow game exceptions,
suppress calls, start saves or perform file I/O. Observer failures cannot escape into
the game caller; they are latched and invalidate/fail our operation instead.

Preparation readiness remains side-effect-free. Pause/death identity, revocable
permission and source checks precede capture. Completion capacity is reserved before
mutation. The completion worker drains owned files and acknowledges player/vehicle DB
work; it never interprets a dequeued task as a committed save. The existing bridge
receipt, worker preparation boundary and backup engine integration are unchanged.

## Layers and version policy

WinUI presents cards and settings; App.Core projects committed preferences and the
actual provider result. GameExtensions owns OS-independent configuration and inclusive
All/Major/Minor version rules. The bridge owns authentication/admission, not game
serialization. The separate SeamlessSave JAR owns the versioned entry, private copies,
original-lock access and compatibility validation. The general backup engine contains
no module-specific branch. The private-call linker carries only per-companion immutable
handles; it is not a global method registry or arbitrary remote invocation facility.

The shared catalogue continues to declare Seamless Saving as All. Major min=42 can
be used for a future vehicle module; Minor supports ranges such as 42.20-42.25.
Explicit override bypasses the declared range only, never essential structure,
identity, admission or completion checks. All is not proof of compatibility with
unexamined binaries. Existing card/modal translations and actual-result reporting remain.

## Validation and remaining work

The ordinary Java checks now combine private-entry execution, nested normal saving,
virtual mod overrides, original-lock ordering, failure cleanup and file ownership.
They replace tests of the retired global-hook implementation rather than accumulating
additional jobs. Existing readiness/pause/death and initial/incremental backup/restore
integration checks are retained. Installed-JAR validation additionally creates the
actual private companions and initializes the production adapter in a separate test
JVM, then checks that original save bodies have not changed. It does not call game
saving or attach to the user's running game.

Two product milestones remain:

1. **Coherent snapshot and bounded capture.** Chunk/animal/native input serialization
   still uses the game thread. The backup engine still reads the live source after
   preparation. Splitting mutable objects across frames without snapshot/mutation
   tracking would mix different item/vehicle states. A genuinely nonblocking design
   must isolate its input and output lifetime, not reintroduce global save hooks.
2. **Disposable-world acceptance.** Reproduce dragging, compare frame times and
   restore unoccupied discovered vehicles, transferred items and mod OnSave data.
   Include normal/mod saves overlapping our request, failure and world exit.
   Synthetic Java tests and installed-bytecode admission are not real-game acceptance.

### Latest local verification

Windows Release solution/WinUI/native/Java build: zero warnings and errors.
`artifacts/game-extension-tests/private-save.trx`: 117 passed, zero failed,
one explicitly skipped live-game probe. The four current Java harnesses pass.
The private-entry harness executes normal saving before/after the extension, a nested
mod save, a virtual subclass override, original-lock ordering, failed writes and
ownership through world invalidation. Existing .NET coverage also connects readiness,
pause and completion to initial/incremental backups and restored bytes.

Using the installed JAR read-only in a separate JVM, the production adapter initializes
successfully and four original save bodies remain canonically identical after its
installation/retransformation. Private companions and three observation transforms
verify; original file-lock/worker field contracts resolve without game initialization.
The four app-worker JARs and catalogue match the build outputs by SHA-256. Removed
global-hook classes are absent from those JARs. These are local checks, not GitHub CI
or real gameplay, drag, frame-time or vehicle-restoration acceptance results.
