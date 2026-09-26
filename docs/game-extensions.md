# Game extensions and private backup saving

[Documentation index](README.md) · [Save bridge](save-bridge.md) · [Live character state](runtime-character-death.md)

## Current scope

Seamless Saving **0.8.0**, bootstrap API **7**, save protocol **6**.
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
lock. A bounded virtual-thread owner acquires that original write lock, opens the
existing file without truncation, and admits a write to ONE platform disk worker
before acknowledging handoff to the game thread. The same owner holds the lock until
writing AND channel close finish, then unlocks and releases the counted reference.
The disk worker never acquires a game lock or reads mutable game objects. Task
submission/completion establishes visibility of the immutable input and write result.
Unmodified ordinary readers/writers still use the same original locks.

Previously the single disk worker also had to acquire each following file lock, so a
blocked write on chunk A delayed capture of independent chunk B. In 0.8 the bounded
owners can secure B while A is writing. Physical writes remain serial and ordered by
admission: the game cannot submit the next chunk until this one has entered the disk
queue. Same-file dependencies and contended lock acquisition may still block.

At most 128 accepted operations/virtual owners/channels and 64 MiB of copied data are
retained. The limit includes operations acquiring a lock, queued writes and cleanup.
Virtual owners do not each create an operating-system thread; inheritance of game
thread-local state is disabled. They terminate when their own resource lease ends.
The single disk worker times out while idle. No per-frame task or polling loop was
added. Java's supported virtual-thread API is used, not JDK-internal access.

Capacity/byte exhaustion, a new file or an unsuitable buffer uses original synchronous
SafeWrite before submission, without skipping data. After admission, lock/open/write/
close failures are errors, not a reason to replay the original write. Completion waits
for every owned lock, channel and copied input; an error remains an error after cleanup.
Shutdown stops new ownership but keeps disk submission open for already-admitted owners.
Cancellation/world change never discards accepted data or interrupts an owned channel.

The channel pins the selected existing file; renaming after handoff does not redirect
its write. Native saving and completion waits remain original and synchronous. There
is no new general-save/stop fence, read-through hook, parallel disk pool or path override.
These immutable per-chunk inputs are NOT a coherent whole-world snapshot, and the
backup engine still reads the live save directory after preparation.

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

### Verification

The existing private-entry harness covers normal saving before/after the extension,
nested mod saves, virtual overrides, original-lock ordering, failed writes and world
invalidation. It additionally holds the first disk write behind a latch while capturing
128 independent chunks, checks one physical writer, scratch-buffer isolation, count
and byte limits, shutdown drain, and lock-acquisition failure without replay.
The gate is released only after capture has returned, so this checks the dependency
rather than relying on a machine-specific millisecond performance threshold.

The existing .NET preparation/initial/incremental/restore tests and installed-JAR
production-adapter/original-body audit are used; no extra CI job or harness was added.
Synthetic and offline checks do not substitute for real-game frame-time, dragging,
vehicle/item restoration or coherent whole-world snapshot verification.

The 0.8 local Windows verification completed: Release solution/WinUI/native/Java build
with zero warnings/errors; `artifacts/game-extension-tests/private-batch.trx` reports
20 passed, zero failed and zero skipped for the selected connected-pipeline regressions.
All four existing Java harnesses passed. The installed-JAR production adapter admitted
in a separate JVM, and the four original save bodies stayed unchanged after observation
instrumentation. Four deployed worker JARs and the shared catalogue matched build hashes.
No actual gameplay save, user-data mutation or real-frame-time measurement was performed.
Bootstrap API 7 and wire protocol 6 did not change in this module-only update.
