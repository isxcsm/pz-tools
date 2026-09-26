# Game extensions and private backup saving

[Documentation index](README.md) · [Save bridge](save-bridge.md) · [Live character state](runtime-character-death.md)

## Current scope

Seamless Saving **0.13.0**, Vehicle Drivetrain **0.2.0** (experimental, default OFF),
bootstrap API **10**, extension host ABI **3**, save protocol **6**.
Install matching app/worker/JARs. Moving from a resident bootstrap API 9 (or older) to 10
requires one complete game restart: the old resident lacks the vehicle dispatcher contract.
After that, compatible module, extension-host and bridge-payload updates are applied
at an idle request boundary, including deployments in another folder. No save or
in-flight native/file/DB operation is interrupted to make an update. Repository data
and game-save formats do not change. See [reload lifecycle](module-reload.md).

This remains experimental low-interruption saving, not a zero-stall or atomic world
snapshot guarantee. The public game save implementation is preserved. The extension
now uses an explicit private, versioned entry rather than intercepting ordinary saves.

Vehicle Drivetrain is a separate continuous provider for the inspected 42.20 code
family. It uses the selected WATCH process/world, not the save-provider slot. It is
not a native tire/collision overhaul or a claim of real horsepower simulation.
Driving settings expose three independent switches: acceleration/transmission,
smooth reverse, and fine keyboard steering. Disabled paths retain original control.
Probe, diagnostics and low-gear tuning remain developer-only TOML options. Version
override remains in technical settings and cannot bypass structural safety checks.
See [design](vehicle-drivetrain-design.md) and [user E2E procedure](e2e-vehicle-drivetrain.md).

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

## Frame-budgeted capture and ordered I/O

The production provider now returns a frame-advanced capture plan rather than calling
the full private save graph in one game-thread turn. Metadata phases and a bounded
number of chunks run between normal frames. The I/O worker prepares file baselines;
no per-chunk ownership future is awaited on the game thread. Checked transfers cause
recapture before final player and all-loaded-vehicle serialization. See
[the current cooperative save design and limits](cooperative-save.md).

The old single-call graph and writer remain in baseline/isolation verification,
not as an automatic retry after a cooperative capture has begun. Original game
save/read/write/stop and normal UI callbacks remain unchanged.

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

The shared catalogue continues to declare Seamless Saving as All. Vehicle Drivetrain
uses Minor 42.20–42.20 plus structural and bytecode admission checks.
Explicit override bypasses the declared range only, never essential structure,
identity, admission or completion checks. All is not proof of compatibility with
unexamined binaries. Existing extension translations and actual-result reporting remain; settings use inline expandable rows without a separate modal.

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

The candidate implements the selected low-interruption path: UI-independent, frame-budgeted admission,
private full-save coverage, bounded chunk write handoff, private native completion,
DB completion, normal-save isolation and the existing backup/restore integration.
See [the disposable-world acceptance procedure](e2e-seamless-save.md).

It is NOT a fully nonblocking serializer: large chunk/animal input capture, original
locks, first-file creation and capacity fallback can still stall. The source remains
the live save directory; an atomic whole-world snapshot is not provided. Neither is
silently declared implemented. A whole-world transaction is not a prerequisite for
testing this candidate, and checked transfer consistency is described in the cooperative capture document.
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

The provider does not read inventory drag tables, input buttons or UI focus to decide
when saving may start. Only save-worker readiness and existing request guards apply.
The private root omits its own SavefileThumbnail.create call, excluding that extra
world/UI render path without replacing ordinary saving or normal frame processing.
OnSave callbacks, including a mod that explicitly invokes normal saving, are preserved.
No input state is cleared, reconstructed, or restored after saving.

The former 0.9.0 drag-idle gate was an avoidance policy, not a fix for UI re-entry. It
was removed together with its tests. The replacement regression actually saves with
held/released-but-unprocessed drag state, checks persisted bytes and no preview callback,
and verifies that legitimate callback cancellation is not resurrected. Its UI state
is synthetic: it does not prove the real inventory event loop or root cause fixed.

Private-only timing wrappers aggregate chunk-body, handoff, animal/native-call and
remaining capture durations. The bounded diagnostic string is carried by the existing
save receipt to backup logs. It is not a new state collector or a frame-time monitor.
Chunk-body time includes original locks/CRC and excludes the measured I/O handoff;
native-call time describes submission/capture, not the off-thread completion interval.
No counter history or per-frame logging is retained. The standard save path is not
wrapped. Existing card/dialog descriptions in all 18 languages state the actual scope.
### Previous 0.9.0 verification (superseded candidate)

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

### 0.9.1 UI-admission correction

Removed InteractionReadiness and its Lua inventory dependency from provider admission.
The existing private thumbnail omission is retained, not a newly invented UI-idle policy.
The replacement test keeps drag/focus active while the actual private graph serializes
and writes files, checks that preview callbacks are not invoked, and also covers a
released button awaiting UI processing and cancellation by a preserved OnSave callback.
Synthetic text-selection/modal-focus values are unchanged. Normal saving still invokes
its rendering callback. These checks are not a real-game input/drag reproduction.

Local Windows verification: Release solution/WinUI/native/Java build passed with zero
warnings/errors; four existing Java programs passed. ui-correction.trx records 58
passed, zero failed/skipped; published-ui-correction.trx records two passed package
checks. Installed-JAR adapter initialization and the five-original-save-body audit passed
in a separate JVM without saving. No new CI job or test harness was added.

The refreshed candidate is artifacts/e2e-seamless-0.9.1/app. Bootstrap API 8 and wire 6
are unchanged. Restart the game for the new module; use the corrected E2E procedure,
not the superseded 0.9.0 drag-wait expectation. Real-game behavior remains unverified.

## Current verification

The reload tests use independently compiled module generations and the actual bridge
inside an isolated JVM. They cover held writes, stale resolutions, invalid archives,
retirement failures, unchanged-byte reuse, deployment relocation, WATCH continuity,
bridge reconnect and retained death identities. Installed-class inspection includes
retiring and reinstalling the production adapter in fresh loaders without game saving.
These are not real-game drag, vehicle-restore or frame-time acceptance results.
