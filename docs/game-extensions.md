# Game extensions and Seamless Saving

[Documentation index](README.md) · [Save bridge](save-bridge.md)

## Live death and execution feedback

The shared runtime now carries independent live character/death facts and the actual
save provider result. See [live-state ownership and validation](runtime-character-death.md).
The extension card's last execution outcome and preparation/total timings are implemented;
the preference itself is never presented as proof of successful application.

## Current implementation (0.5, experimental)

The Game Extensions page contains the Seamless Saving card, a persisted toggle and
an Apply/Cancel settings dialog. The toggle records the user's preference, not an
already applied game patch. Compatibility is checked on the next backup request.
All 18 UI languages describe the actual experimental scope.

The module now has an executable adapter for the locally inspected Build 42.20 /
Java 25 game classes. It **does not yet implement fully nonblocking world saving**.
It keeps the original `GameWindow.save(true)` on the game thread, suppresses only
that request's forced thumbnail render, and waits off-thread for post-capture
player/vehicle database drains, bounded deferred existing-chunk writes, and eligible
collision/population native completion. See [native wait boundary](seamless-native-wait.md). Chunk
serialization, first file creation, over-budget writes and native world-save waits
still use the original synchronous game code. This is not a zero-stall guarantee.
No reduction in real-game frame stalls or drag cancellation is claimed without a
separate live-game comparison. The last thumbnail is retained rather than refreshed
by this request. Normal game saves still create their thumbnails.

## Integrated dev runtime and version policy (0.4)

This branch integrates dev `2a24df1` (including PR #12 pause-aware scheduling and
the subsequent inline log-filter and recovery-guidance updates). Observation and save requests use one bootstrap and one
GameWindow dispatch hook. Observation has its own read-only session; it does not
hold the exclusive save slot. Both consumers share process/world identities.
The runtime stream now adds optional game-version metadata. The metadata getter
runs once per observation generation, not once per frame, and failure to read it
does not invalidate the independent pause sample. The app reuses its existing
runtime feed and does not start a second Attach process when opening extension cards.
Pause scheduling is a policy consuming this shared runtime, not its lifetime owner.
Turning pause-aware scheduling off no longer disables the metadata feed needed by
extension cards; it still disables the pause-specific scheduling policy.

Both original branches had independently assigned wire protocol 5. Protocol 6 and
bootstrap API 4 identified the integrated implementation (current bootstrap API: 5). Restart the game
once after installing matched app/worker/JAR files. A guarded extension request
carries its runtime ticket, provider ID and explicit version override together.
Pause, epoch, replay and pre-submission permission checks still apply before save
admission; a late pause/cancel cannot abort already-owned file/database writes.
RecoveryStamp metadata is recorded before either standard or extension capture.

`config/game-extensions/catalog.tsv` is the single deployment catalogue read by the
UI and JVM. It is also embedded as the management library's offline default. The
worker build stages it alongside the JARs. The catalogue defines inclusive ranges:

| Scope | Min / max | Meaning |
| --- | --- | --- |
| All | - / - | No declared version restriction (Seamless Saving now uses this) |
| Major | 42 / - | Major 42 and later; groundwork for a future vehicle module |
| Major | 42 / 42 | Only major 42, all its minor/patch versions |
| Minor | 42.20 / 42.20 | The 42.20 line, including patch versions |
| Minor | 42.20 / 42.25 | Inclusive minor-version range |

Comparisons use numeric components, not text ordering or decimal numbers. Unknown
versions do not match a restricted range. No vehicle module/card is added yet.
A mismatched card disables its ordinary activation toggle without erasing the saved
preference. Settings remains available: the user can explicitly enable the version
override, read its warning and apply both preference values atomically. Disabling an
extension preserves its settings. Current/supported versions and override states are
localized in all existing UI languages. Current version is from the running game,
never from a backup's save-format number. Stale/disconnected metadata becomes unknown.

**A declared range is not proof that arbitrary bytecode can be patched safely.**
All allows activation requests for all versions, but the current implementation's
low-level adapter still validates the inspected 42.20 game classes. Unsupported
bytecode uses standard saving with a reason. The explicit override bypasses ONLY
the declared range, not authentication, pause guards, world identity, modifiability,
method layout, serialization checks or write-completion fences. A future adapter
can broaden actual support in its own module package. Do not present All as testing
or successfully patching every game release.

### Remaining work — concrete boundaries

1. **Chunk serialization is still synchronous.** Only bounded writes to existing
   chunk files leave the game thread. Large in-memory chunks can still stall it.
   Safe snapshot capture/consistent incremental serialization has not been built.
2. **Remaining native work is synchronous.** The collision/population worker's
   explicit completion wait is now handed off in 0.5. Native input preparation,
   shared-lock contention and other subsystems (including animals) still need work.
3. **No immutable whole-world backup input.** The engine still captures the live
   save folder after preparation. Cross-file point-in-time consistency, including
   moving items between containers and player inventory, is not guaranteed.
4. **Drag cancellation and frame-time improvement are not verified in a real game.**
   The module suppresses its forced thumbnail render, but the actual input-reset
   cause and its resolution still need an isolated-world reproduction.
5. **Real-game restore coverage is pending:** discovered-but-unoccupied vehicles,
   inventory transfers, mods' OnSave data, interrupted writes, world exit and reload.
   Synthetic Java tests do not replace these checks.
**Completed follow-up:** The card now shows the last admitted extension-save outcome,
actual provider/fallback code, and game-thread preparation/total timings from the shared
runtime stream. This is session-scoped observed execution, not a persistent result archive.
The installed-game structural check now also includes IsoChunk (five verified classes);
real-game behavior and restoration checks above remain outstanding.

This integration does not claim to finish the remaining nonblocking save work.
No real game is attached/saved by its automated validation; all mutation fixtures
use private temporary folders and synthetic JVMs.
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
2. Protocol 6 sends one `PREPARE_SAVE` request containing the requested provider.
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

The current bootstrap API 4 includes the stable file-handoff interface and requires one complete game restart.
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

## Validation of runtime integration and version policy (0.4)

Windows Release solution including WinUI/XAML, Java and native bootstrap built with
zero warnings/errors. The final targeted run passed **99/99**, with no skipped
cases (`runtime-extension-final.trx`). It includes version policy, preferences,
projections, pause/schedule logic, localization, and real protocol traffic between
the existing synthetic JVM/watch/provider fixtures. The combined case verifies
that force cannot bypass a pause before admission, a pause after writer admission
does not drop ownership, watchers continue during a pending write, both paths use
the same process/world identity, replay is rejected, and removing force after a
cached module load restores normal version gating.

The earlier broader run passed 130, failed one, and skipped one explicitly opt-in
live probe. The failure was an unintended readiness-code rename; the existing
contract was restored, not its assertion removed. The final 99 include that case.
Counts overlap and do not mean a complete application regression run.
All five small Java harnesses passed, including 14 numeric version-range cases
shared with .NET. Actual gameplay, interactive WinUI, real-world restores and
performance improvements are not newly verified by this integration.
The final UI-only dev update `2a24df1` was then integrated as well, preserving its
inline log filtering and shorter recovery guidance. Its resource conflicts were
resolved by retaining every dev resource value and adding extension-specific keys.
The full Release build still passed with zero warnings/errors, and the affected
UI-filter/localization/version-policy tests passed **54/54** (`latest-dev-ui.trx`).
These overlap the 99-case integration run; runtime/save code was not changed by
this final dev update. Neither dev nor main was modified by this branch integration.