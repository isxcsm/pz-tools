# Game extensions and Seamless Saving

[Documentation index](README.md) · [Save bridge](save-bridge.md)

## Current implementation (0.2, experimental)

The Game Extensions page contains the Seamless Saving card, a persisted toggle and
an Apply/Cancel settings dialog. The toggle records the user's preference, not an
already applied game patch. Compatibility is checked on the next backup request.
All 18 UI languages describe the actual experimental scope.

The module now has an executable adapter for the locally inspected Build 42.20 /
Java 25 game classes. It **does not yet implement fully nonblocking world saving**.
It keeps the original `GameWindow.save(true)` on the game thread, suppresses only
that request's forced thumbnail render, and waits off-thread for post-capture
player/vehicle database drains. Chunk serialization, chunk file writes and native
world-save waits still execute through the original synchronous game code.
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
   installs four scoped hook points once, and retains its loader for this JVM.
   Other agents modifying these methods are not universally supported.
4. On the game thread it runs the original save, including OnSave, loaded chunks,
   their vehicle updates, native subsystems and virtual vehicles. It then consumes
   the player force-save flag and vehicle main-thread preparation in that tick.
   Only the thumbnail call inside this module request is suppressed.
5. A completion ticket is armed after capture. Player and vehicle drain calls
   must **start after** that boundary and finish successfully. An empty queue or
   an earlier drain is insufficient. Scoped logged exceptions fail the ticket.
6. A module worker waits for the ticket. Game-loop polls only observe completion;
   they do not join the worker. The response is sent after module cleanup.
   Only then can the existing backup preparation continue to file capture.

## Guarantees and limitations

`STANDARD_CALL_RETURNED`, `DETACHED_WRITES_COMMITTED`, and
`GAME_SAVE_AND_DATABASE_QUEUES_DRAINED` are different observations. The production
B42.20 adapter reports the last one. It does not claim a frozen cross-file world
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

The bootstrap API upgrade in this change requires one complete game restart.
After that, module updates also require a game restart; toggles do not reload JARs
or repeatedly retransform classes. The optional module's compatibility data stays
in its own JAR. Unsupported game fingerprints fall back before saving, provided
the base bridge is still compatible. A broken base bridge remains an error.

No repository schema change or save reset is required. The Windows discovery and
native Attach adapter remain platform-specific; management models and the Java
module API do not depend on WinUI. Install matched app/worker/bootstrap components.

## Focused validation for this iteration

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
