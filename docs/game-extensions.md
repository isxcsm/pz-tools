# Game extensions and private backup saving

[Documentation index](README.md) · [Save bridge](save-bridge.md) · [Live character state](runtime-character-death.md)

## Current scope

Seamless Saving **0.9.0**, bootstrap API **8**, save protocol **6**.
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
                                  -> private GameWindow / IsoCell / ChunkMap / Chunk / native-save bodies
                                  -> original serializers, native saving and guarded chunk I/O
```

`PrivateSaveGraph` builds five hidden nestmate companions from the inspected game
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
its write. The private native copy can also hand off its completion wait under the
original snapshot lock, as described below. Public save/stop remain unchanged; no
public read-through hook, extra native writer or path override is added.
These immutable per-chunk inputs are NOT a coherent whole-world snapshot, and the
backup engine still reads the live save directory after preparation.

The previous FileWriteHooks/SaveWaitHooks, public SafeRead read-through, JDK-internal
file-key adapter, auxiliary-output rewrites and native save/stop rewrites were removed.
They are not hidden fallback modes. Some earlier optimizations are consequently no
longer active; no performance improvement over 0.6 is asserted without measurements.

## Observation and ownership

The existing game-loop dispatch and WATCH session still supply pause, version, live
character/death and execution status. Saved players.db state stays independent.
Four narrow read-only observers cover PlayerDB/VehicleDB drains, ExceptionLogger
errors and the existing native worker's save entry/exit. They do not replace serializers, swallow game exceptions,
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

### Acceptance boundary

The candidate implements the selected low-interruption path: drag-safe admission,
private full-save coverage, bounded chunk write handoff, private native completion,
DB completion, normal-save isolation and the existing backup/restore integration.
See [the disposable-world acceptance procedure](e2e-seamless-save.md).

It is NOT a fully nonblocking serializer: large chunk/animal input capture, original
locks, first-file creation and capacity fallback can still stall. The source remains
the live save directory; an atomic whole-world snapshot is not provided. Neither is
silently declared implemented. A whole-world transaction is not a prerequisite for
testing this candidate, but safe multi-frame serialization needs additional design.
Real-game dragging, frame times, other mods and restored vehicles/items are unverified
until the acceptance run; synthetic tests do not establish those results.
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


## Private native completion (0.9)

Only the private MapCollisionData.save companion changes its wait branch. Its original
input preparation, flag publication, notification, two native save calls and verified
no-op endSaveRealZombies are retained. The real MCDThread is the only native writer.

A read-only worker observer identifies the precise n_save entry and the matching exit
after BOTH native calls and flag reset. A bounded virtual owner waits for that entry
BEFORE acquiring the original ZombiePopulationManager.saveLock. Acquiring this lock
earlier could deadlock an older processPendingSaveCells phase; the fixture covers it.
The private caller returns from its wait only after ownership is secured. Original
beginSaveRealZombies/requestSaveCell calls then use their unchanged lock and cannot
replace the captured native input. The owner releases on acknowledgement or confirmed
worker termination, never on client cancellation or world invalidation alone.

Errors belong to the observed native phase, are retained across game-internal retry,
and cannot be turned into success by a later request. Unmodified stop still joins its
worker. Native acknowledgement precedes the worker's later pending-cell lock, allowing
our owner to release without a stop/lock cycle. Unavailable workers or subclassed
population implementations retain original synchronous saving. Live method fingerprints
also cover native begin/end/worker/stop contracts. Arbitrary third-party JNI patches
or failures hidden inside C++ are not asserted safe/detected by these Java checks.

## Interaction and per-request diagnostics (0.9)

The optional provider waits before mutation while an inventory drag/drop is still pending. A held mouse button alone does not block
normal play or combat. It reads the current Lua table on
the game thread and never resets input, clears a drag or recreates item references.
Mouse release alone is insufficient: the UI must also finish its drop handling.
Existing request lifetime, pause/death checks and cancellation apply during this wait;
a stuck interaction times out WITHOUT saving, rather than being force-cleared.

Private-only timing wrappers aggregate chunk-body, handoff, animal/native-call and
remaining capture durations. The bounded diagnostic string is carried by the existing
save receipt to backup logs. It is not a new state collector or a frame-time monitor.
Chunk-body time includes original locks/CRC and excludes the measured I/O handoff;
native-call time describes submission/capture, not the off-thread completion interval.
No counter history or per-frame logging is retained. The standard save path is not
wrapped. Existing card/dialog descriptions in all 18 languages state the actual scope.
### 0.9 local candidate verification

The final Windows Release solution/WinUI/native/Java build completed with zero
warnings and zero errors. The existing four Java harness programs passed, including
the combined private-native lock/phase tests and read-only drag readiness cases.
`interaction-candidate.trx` contains 58 passed, zero failed and zero skipped cases.

A fresh publish-app output was produced at `artifacts/e2e-seamless-0.9.0/app`.
`published-interaction-candidate.trx` contains six passed, zero failed and zero skipped
cases using that published payload: two distribution checks plus initial/incremental
backup/restore, provider ownership/diagnostic propagation, pause/version and live death.
The two test selections overlap and are not summed as unique test coverage.

The production adapter initialized against the installed game JAR in a separate JVM.
Private companions and observers verified, and the five original save bodies remained
unchanged after instrumentation. This did not execute game saving or native gameplay.
The four published JARs, native bootstrap DLL and shared catalogue matched the current
build outputs by SHA-256. No new CI job, workflow or harness process was added.

This verifies the candidate's implementation and packaging, not real-game stutter,
FPS, drag behavior or restoration of actual vehicles/items. Those acceptance results
remain unmeasured. The running user app, game installation, real saves, backup databases
and user configuration were not changed by the development or automated verification.
