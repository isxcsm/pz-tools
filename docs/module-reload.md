# Compatible JVM component updates

[Game extensions](game-extensions.md) · [Save bridge](save-bridge.md)

## User-visible policy

Bootstrap API **9**, extension API **2**, save wire protocol **6**.
A resident API 8 or older cannot gain this lifecycle retroactively: migrate with one
game restart. With API9 resident, compatible updates are detected at the next request.
The app executable may still need restarting for its own files; the game need not.
This is module replacement under a resident agent, not forced JVM class unloading.

| Change | Behavior |
| --- | --- |
| Same JAR bytes / same definition | Reuse the loaded generation |
| Compatible module bytes or catalogue definition changed | Retire old provider before initializing its replacement |
| Extension runtime JAR changed | Drain and close its module host, then load a new host |
| Same bytes in another install directory | Adopt the directory without reinstalling the game-loop hook |
| Bridge payload changed | Stop WATCH cooperatively, drain callbacks, replace payload, reconnect WATCH |
| Active save or unfinished cleanup | No replacement; accepted work retains its owner |
| Invalid new archive | Reject before retiring the current module; report standard-provider fallback |
| Uncertain retirement / incompatible resident API | Do not force cleanup or replay saving; restart required |

A module check runs on an explicit save request, not every game frame or filesystem
notification. Updating files during a save does not change that accepted request.
The next request selects the new generation after the old one has finished.
Save diagnostics include `moduleVersion` and the SHA-256 of the exact loaded JAR.
This is the actual executed module, not merely the version requested by a toggle.

## Lifecycle and ownership

JAR bytes are read into one bounded closed snapshot; manifest validation, hashing and
class definition use those same bytes. The old instance is not disposed merely because
a newly written archive cannot be opened. Initialization never overlaps a live save.
Unsupported initializers are cached for that exact definition/digest, rather than
repeatedly installing probes on every backup. A corrected package invalidates the cache.

Providers explicitly opt into retirement. The real save adapter removes its transformer,
restores only its observation targets through JVM retransformation, waits for registered
callbacks and closes idle executors. Existing third-party transforms are composed by
the JVM; raw original class files are not forced over them. Late transformer calls see
a retired flag. Cleanup timeouts poison that host instead of admitting another version.

Observation enter/exit is paired to the registration that began the call. An exit from
an older frame cannot complete a newly registered observer. Hook names remain stable
so a native frame already running when classes are retransformed can later enter the
current observer; the pairing token, not a module-specific string, owns each scope.
Retired callback state is removed and reused empty stacks retain no module references.
Hidden companions become collectible after references disappear. Their named game-loader
lookup helper is defined only once, not leaked once per module update.

Module/extension-host replacement leaves WATCH running. Bridge payload replacement
briefly retires the old subscription; the existing state coordinator reconnects it.
Process/world/character/death identities live in the stable parent. Observer epochs
change and old scheduling tickets become invalid. No past death is synthesized again.

Original game save/read/write/stop and UI handling remain unchanged. This lifecycle
adds no UI-idle gate, no new per-frame collector, and no automatic replay of a save.
Ordinary saves can still contend for existing game locks with accepted private writes.

## Local verification

The final Windows Release solution (including WinUI, native bootstrap and Java) built
with zero warnings/errors. `artifacts/game-extension-tests/module-reload.trx` contains
21 passed tests, zero failed and zero skipped. Four existing Java harness entry points
pass; the reload scenarios are called from those harnesses, not additional CI jobs.

The connected test keeps the same JVM alive while changing module bytes during an
owned write, moving the deployment directory, replacing the bridge payload and then
replacing the extension host. It checks actual module-instance changes, WATCH epochs,
process/world/character/death identity, stale ticket refusal and one game-loop hook.
Separate host tests execute differently compiled provider code and reject corrupt
packages, stale resolutions and failed retirement without overlapping generations.

The installed game JAR is used read-only in a separate JVM: production adapter
admission and original save-body fingerprints pass. Three fresh module loaders can
initialize and retire the real adapter with no observer registrations or named lookup
helpers accumulating. No game saving or native game initialization is performed.

Fresh publish-app output and two published-distribution checks pass. The publisher's
missing JdkPath propagation into the App build was fixed rather than relying on a
machine-wide JAVA_HOME. Published JARs, native DLL and catalogue match build hashes.
This is not live-game frame-time/drag/vehicle-restore acceptance or a promise that GC
will immediately unload retired classes. Real user saves/settings were not changed.
