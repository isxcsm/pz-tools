# Game extensions and Seamless Saving

[Documentation index](README.md) · [Save bridge](save-bridge.md)

## Current implementation (0.3, experimental)

The Game Extensions page contains the Seamless Saving card, a persisted toggle and
an Apply/Cancel settings dialog. The toggle records the user's preference, not an
already applied game patch. Compatibility is checked on the next backup request.
All 18 UI languages describe the actual experimental scope.

The module now has an executable adapter for the locally inspected Build 42.20 /
Java 25 game classes. It **does not yet implement fully nonblocking world saving**.
It keeps the original `GameWindow.save(true)` on the game thread, suppresses only
that request's forced thumbnail render, and waits off-thread for post-capture
player/vehicle database drains and bounded deferred existing-chunk writes. Chunk
serialization, first file creation, over-budget writes and native world-save waits
still use the original synchronous game code. This is not a zero-stall guarantee.
No reduction in real-game frame stalls or drag cancellation is claimed without a
separate live-game comparison. The last thumbnail is retained rather than refreshed
by this request. Normal game saves still create their thumbnails.

## Boundaries

- `PzTools.GameExtensions` owns platform-independent settings, preference revisions
  and save-provider policy. Neither WinUI nor game classes are dependencies.
- `PzTools.App.Core` projects preferences; `PzTools.App` displays cards and dialogs.
- `PzTools.Zomboid.Backup` selects the configured provider. `PzTools.SaveBridge`
  owns the existing authenticated transport and decodes typed completion receipts.
- The bootstrap owns the stable Java API and bounded archive loader. The extension
  runtime and game-sensitive module are separate JARs. Game classes are not shipped.

`SaveModules` is a capability host, not a requirement that every future extension
implement saving. A driving extension needs its own capability contract. The
current catalogue is curated; arbitrary JAR installation, a marketplace and hot
code replacement are outside this implementation. Class loaders isolate type
ownership, not malicious Java code. Only trusted modules are supported.

## Actual request sequence

1. The worker reads extension preferences. Disabled or malformed optional settings
   retain standard saving. Disabling pre-backup game saving itself still takes
   precedence; enabling an extension does not override that preference.
2. Protocol 5 sends one `PREPARE_SAVE` request containing the requested provider.
   The JVM resolves compatibility before any save starts. An unavailable module
   falls back in the same session, with a reason. Ordinary SAVE/PROBE requests
   do not load the extension runtime.
3. The B42.20 adapter verifies inspected class fingerprints and method shapes,
   installs scoped hooks in five classes once, and retains its loader for this JVM.
   Other agents modifying these methods are not universally supported.
4. On the game thread it runs the original save, including OnSave, loaded chunks,
   their vehicle updates, native subsystems and virtual vehicles. It then consumes
   the player force-save flag and vehicle main-thread preparation in that tick.
   Forced thumbnail rendering is suppressed. Completed chunk byte buffers may be
   handed to the bounded writer; the original chunk/vehicle serializers stay unchanged.
5. A completion ticket is armed after capture. Player and vehicle drain calls
   must **start after** that boundary and finish successfully. An empty queue or
   an earlier drain is insufficient. Scoped logged exceptions fail the ticket.
6. A module worker waits for the ticket. Game-loop polls only observe completion;
   they do not join the worker. File handles and buffers are drained before module
   cleanup, including failure, cancellation and world-exit paths.
   Only then can the existing backup preparation continue to file capture.

## Guarantees and limitations

`STANDARD_CALL_RETURNED`, `DETACHED_WRITES_COMMITTED`, and
`GAME_SAVE_AND_DATABASE_QUEUES_DRAINED` are different observations. The updated
B42.20 adapter reports `GAME_SAVE_AND_PENDING_WRITES_DRAINED`: both its detached
chunk writes and the post-capture DB fences have completed. It does not claim a frozen cross-file world
snapshot, durable hardware flush, or detection of every internally swallowed
native/Lua error. The generic detached-write runtime is tested separately.

No generic `runAsync(save(true))`, fixed completion sleep, blanket UI-state restore
or partial player-only/occupied-vehicle save is used. The source world is not moved
to a staging directory; its existing file identity and USN boundaries are retained.
A future immutable-input design must explicitly separate logical source identity
from any staging filesystem's file IDs and USN journal.

Cancelling a queued request prevents saving. Disconnecting during a module write
retains ownership and the game-loop callback until completion. No standard save is
replayed after a provider begins. World-cell identity, request/session/world IDs,
and periodic world/path validation prevent accepting a stale completion. A world
ending causes the completion waiter to fail rather than reporting an offline skip.

## Deployment and compatibility

Bootstrap API 3 adds the stable file-handoff interface and requires one complete game restart.
After that, module updates also require a game restart; toggles do not reload JARs
or repeatedly retransform classes. The optional module's compatibility data stays
in its own JAR. Unsupported game fingerprints fall back before saving, provided
the base bridge is still compatible. A broken base bridge remains an error.

No repository schema change or save reset is required. The Windows discovery and
native Attach adapter remain platform-specific; management models and the Java
module API do not depend on WinUI. Install matched app/worker/bootstrap components.

## Previous iteration verification

Local Windows Release solution, WinUI/XAML, native bootstrap and Java builds
succeeded with zero warnings/errors. The related .NET run passed 96 tests with one
explicit live-game probe skipped; no live-game environment opt-in was enabled.
The additional provider transport test uses a test-only JAR in a private copied
bridge folder, never in application output. It verifies that the synthetic game
loop keeps processing while a write waits, failed writes are not replayed, and
transport cancellation retains admission until cleanup completes.

Three short Java harnesses check detached writes/ownership, post-capture database
fences/errors/world invalidation, and execution of transformed generated classes.
The four target classes in the installed game JAR were also transformed and checked
with the Java ClassFile verifier **offline, without executing game code**.
That local check is optional and is not required by CI or redistributed with game bytes.

Live drag handling, discovered-but-unoccupied vehicle restoration, native saving
under real mods, full distribution testing and frame-time measurements remain
unverified. Fully nonblocking chunk/native persistence requires a separate coherent
snapshot design; this release does not hide that gap with a thread-pool wrapper.

## Ordered chunk-file handoff (0.3)

The module intercepts only the stream-I/O section of `IsoChunk.SafeWrite` and
adds a pre-read fence inside `SafeRead`. Original per-chunk game locks, directory
handling, serialization, vehicle side effects and exception/finally blocks remain.
The boolean overloads of `IsoChunk.Save` are NOT swapped: their vehicle side
effects differ. Native save operations and Lua callbacks remain on their original thread.

Existing ordinary files may be deferred only during our capture on the game thread.
The target is resolved by the game and opened with WRITE + NOFOLLOW_LINKS, without
creation or truncation. This pins the file identity before handoff, so a later
world switch or replacement path does not redirect the older write. The worker
receives an owned byte-array copy and that channel, never a mutable game chunk,
a shared ByteBuffer view, or a deferred lookup of the current world's path.

A single writer preserves submission order. All protected reads and synchronous
writes wait for earlier deferred writes to the same path. Original/exit saves
also fence outstanding writes before entering their normal synchronous save.
The module's own capture bypasses that global fence; it never waits for its entire
batch on the game thread. The worker does not acquire game locks, avoiding a
lock inversion when a game reader waits while holding its original chunk lock.

A new file is deliberately created synchronously: loaders may test existence before
SafeRead. Non-regular files and unsupported buffer forms retain original I/O.
The runtime provides a 64 MiB owned-byte budget; the module also caps queued plus
in-flight channels/jobs at 128. Exhaustion falls back to ordered original I/O,
not a dropped chunk, an unbounded queue, or a smaller save scope. File opening,
copying, a same-file read/write dependency, and fallback writes can still stall.
The writer is a daemon and retires after idle time; abrupt JVM termination is not
an acknowledged completed save and has no crash-durability guarantee.

Write and channel-close failures fail the owned batch. File completion is observed
after all owned channels have closed, even if the world ends or waiting is interrupted.
This is not a new staging filesystem and does not change source IDs or USN tracking.
It does not make subsequent live-directory backup capture a world-wide atomic snapshot.

The game-free chunk harness executes the actual transformed SafeWrite/SafeRead
shapes on Windows files. It covers detached-buffer reuse, read/write ordering,
new-file visibility, byte/job bounds, executor rejection, write failure, old-path
replacement, original/exit-save fences and combined file/DB completion. No
wall-clock speed threshold or source-string assertion is used. The existing
small bridge suite remains the integration gate; no new CI job is introduced.
## Validation of 0.3

- Final Windows Release solution, WinUI/XAML, native/Java build: success, no warnings/errors.
- Four short Java behavior harnesses passed, including execution of the actual I/O transform on a game-free fixture.
- Initial wider .NET run: 95 passed, one failed, one explicit live probe skipped (97 total).
  The failure was a fixture race: its writer-close marker precedes game-loop callback release.
  The test now awaits the actual idle condition and still checks ownership and absence of replay.
- That test and its two adjacent protocol cases passed on a scoped rerun (3/3).
- Final current-code extension/policy/localization/provider checks passed 72/72 with no skips.
  These sets overlap; the entire wider set was not repeated after the final scoped edits.
- TRX files: `artifacts/game-extension-tests/chunks-initial.trx`, `chunks-targeted.trx`, `chunks-final.trx`.
- App-worker bootstrap, payload, runtime and module JAR hashes match the current build outputs.
- The additional offline check against the installed game's new IsoChunk transformation was NOT executed:
  the terminal request was blocked by the tool. The earlier four-class verification above is historical,
  not validation of this iteration's new real-game transformation. No workaround or live-game attach was used.

Real-game drag preservation, vehicle restoration, frame times and full publication testing remain unverified.
This branch remains experimental; partial background I/O must not be described as a completely nonblocking save.
