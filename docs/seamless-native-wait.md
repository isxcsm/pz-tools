# Seamless Saving: native completion wait (0.5)

[Game extensions](game-extensions.md) · [Save bridge](save-bridge.md)

## Implemented boundary

This iteration changes one specific wait, not all native persistence:
`MapCollisionData.save()` waiting for the existing `MCDThread.save` flag.
The installed Build 42.20 bytecode was read offline. The original sequence is:

1. Game thread: `beginSaveRealZombies()` prepares the original native input.
2. Game thread: set the worker's volatile `save` flag and notify its notifier.
3. MCD thread: collision `n_save()`, then `ZombiePopulationManager.save()`.
4. MCD thread: clear `save` only after both calls return normally.
5. Game thread: stop sleeping and call `endSaveRealZombies()`.

In this inspected build the final cleanup method has no non-client work. Its class
fingerprint is part of the compatibility checks: future implementations that need
post-write cleanup must not inherit this adapter by a guessed version match.
The native thread already owns its normal `renderLock` while writing; it is not
replaced with an application thread. Native implementation internals remain opaque.

For our module's capture, the original submission and cleanup calls run unchanged,
but the flag wait is handed to the existing module completion worker. The original
native thread does the work. Chunk serialization, player/vehicle capture, OnSave,
animal and remaining save subsystems are not omitted or moved to arbitrary threads.

## Ownership and ordering

- Eligibility requires the expected owner, the capture's game thread, a live native
  worker, and no outstanding native request when entering the original method.
- The deferral hook executes only after original submission/notification. A cleared
  flag before reaching the hook simply follows the original synchronous path.
- Completion requires the captured worker's volatile flag to clear. Queue emptiness
  or a timer is not used as proof. Logged errors on that worker while `save` is set
  fail the batch, including a later successful retry by the game's own thread.
- If the native worker terminates with its flag still set, the request fails. If it
  remains alive without clearing it, ownership remains pending; the existing bridge
  timeout reports completion unknown, not success. We neither clear that flag nor
  forcibly kill native work.
- A later ordinary GameWindow save, direct collision save, or collision teardown
  waits for a preceding deferred write before preparing new native data or stopping
  its worker. Those exceptional/dependent paths may still block, intentionally.
- World invalidation or interrupted module waiting cannot abandon an in-flight
  native write. Cleanup drains it even when file waiting already failed. New module
  saving retains the existing single-request ownership and no fallback-after-start.
- A single per-request native fence is retained, not a queue of game objects. It is
  released on cleanup. No extra polling process, Attach session or native worker was
  added. No save is performed merely to obtain live state.

The only common addition is `SaveWaitHooks`, an optional, game-independent handoff
contract. Fields, bytecode patterns and fingerprints remain in the B42.20 module.
A missing handler leaves normal calls untouched. The new stable API requires
bootstrap API **5**; wire protocol 6 and the runtime/death contracts are unchanged.
The module version is **0.5.0** and its declared range remains All. Structural
compatibility checks, not the All label or the user override, decide safe patching.

## Validation scope

`NativeSaveWaitTest` runs the actual transformer and production completion fence on
isolated generated game-like classes with controllable Java workers. It verifies
same-game-executor progress while writes wait, both original write calls, ordinary
save/exit ordering, logged errors, interrupted waiting, world invalidation, native
thread death and vanilla fallback. Existing file/DB, pause, death and provider tests
remain separate and reusable. No fixed millisecond performance assertion is used.

The optional installed-JAR verifier also includes MapCollisionData. It reads and
transforms bytes offline and checks ClassFile validity; it never initializes the
game classes, attaches to a running game, saves a world or changes the installed JAR.
The native surrogate is only compiled under test artifacts, never product JARs.

## Not completed by this change

- Chunk-to-byte serialization and first-file/over-budget synchronous I/O remain.
- `beginSaveRealZombies()` capture/lock acquisition, animal and other synchronous
  native work remain. Shared native locks may still stall another game path.
- No immutable cross-file world snapshot is provided to the backup engine.
- Native functions returning normally do not prove hardware durability or detect
  every internally swallowed native/Lua error.
- Real drag behavior, discovered-but-unoccupied vehicles and item-transfer restore,
  frame-time changes and native behavior under real mods still need a test world.

This removes the explicit collision/population wait from eligible module captures;
it is not evidence that real gameplay has become stall-free.

## Recorded local validation (2026-09-26)

- Windows Release solution/WinUI/native/Java build: 0 warnings, 0 errors.
- Scoped .NET run `artifacts/game-extension-tests/native-wait.trx`: 49 passed,
  0 failed, 0 skipped. Includes live-death, guarded pause, version override and
  provider ownership paths using synthetic JVMs, not the user's game.
- Six small Java harnesses passed, including native interruption/ordering and the
  existing shared version/file/database cases. These groups are not additive.
- Final offline verifier passed for GameWindow, PlayerDB, VehiclesDB2,
  ExceptionLogger, IsoChunk and MapCollisionData.
- App-worker bootstrap, payload, runtime, module JARs and catalogue SHA-256 match
  current build output. No extra CI job or repeated full .NET suite was added.
- No real-game saves, live drag test, native performance run or vehicle/item restore
  was performed. These local results are not a GitHub CI success claim.