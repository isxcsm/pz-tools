# Compatible JVM component updates

[Documentation index](README.md) · [Game extensions](game-extensions.md) · [Save bridge](save-bridge.md)

## User-visible policy

Bootstrap API **10**, extension host ABI **3**, save wire protocol **6**.
A resident API 9 or older cannot gain the continuous vehicle dispatcher retroactively:
migrate with one game restart. With API10 resident, compatible component updates
are detected at a request or extension-control boundary. The app executable may
still need restarting for its own files. This is module replacement under a
resident agent, not forced JVM class unloading.

Vehicle Drivetrain is the shipped extension. No optional save provider is deployed;
active-world backups use the original game-thread `GameWindow.save(true)` call.
Common save-provider/checkpoint contracts remain for host compatibility and tests.

| Change | Behavior |
| --- | --- |
| Same JAR bytes / same definition | Reuse the loaded generation |
| Compatible module bytes or catalogue definition changed | Retire old provider before initializing its replacement |
| Extension runtime JAR changed | Drain and close its module host, then load a new host |
| Same bytes in another install directory | Adopt the directory without reinstalling the game-loop hook |
| Bridge payload changed | Stop WATCH cooperatively, drain callbacks, replace payload, reconnect WATCH |
| Active save or unfinished cleanup | No replacement; accepted work retains its owner |
| Invalid new archive | Reject before retiring the current module |
| Uncertain retirement / incompatible resident API | Do not force cleanup or replay saving; restart required |

Continuous vehicle modules use a leased control session and settings revisions;
they do not wait for a backup. Validated settings apply at the vehicle's safe
boundary. Desired and applied revisions distinguish a saved preference from an
installed configuration. See [vehicle lifecycle and acceptance](e2e-vehicle-drivetrain.md).

## Lifecycle and ownership

JAR bytes are read into one bounded closed snapshot; manifest validation, hashing
and class definition use those same bytes. A newly written archive that cannot be
opened does not by itself dispose the old instance. Unsupported initializers are
cached for that exact definition/digest; a corrected package invalidates the cache.

Providers explicitly opt into retirement. Module cleanup stops new admissions,
drains callbacks and releases owned resources before another generation can use
them. Cleanup timeouts poison the host instead of admitting another version.
The vehicle lifecycle also handles lease expiry, world/process identity changes
and revocation while the game is paused. Its restoration and failure boundaries
are described in the [vehicle design](vehicle-drivetrain-design.md).

Module/extension-host replacement leaves WATCH running. Bridge payload replacement
briefly retires the old subscription; the existing state coordinator reconnects it.
Process/world/character/death identities live in the stable parent. Observer epochs
change and old scheduling tickets become invalid. No past death is synthesized again.

A disconnected request cannot cancel an admitted synchronous game save. The call
must return before its ownership can be released. Component replacement adds no
automatic replay of a save and does not turn a returned game call into an atomic
whole-world snapshot guarantee.

## Verification boundary

The common module-reload harness uses synthetic save providers to verify in-flight
ownership, changed module bytes, directory relocation, bridge payload replacement
and extension-host replacement. It checks WATCH epochs, process/world/character/
death identity, stale scheduling tickets and a single game-loop hook. Host tests
also reject corrupt archives, stale resolutions and failed retirement without
overlapping generations.

Vehicle tests cover control-session ownership, settings revisions and cleanup.
Installed-class checks use a local game JAR read-only in an isolated JVM; they do
not attach to a running game. Refer to current harness/TRX and published-package
checks for results from a particular build. These checks are not live-game
performance or restoration acceptance, nor a promise that GC immediately unloads
retired classes.
