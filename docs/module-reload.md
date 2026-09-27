# Compatible JVM component updates

[Documentation index](README.md) · [User guide](../README.md)

## User-visible policy

Compatible component updates are detected at a request or extension-control
boundary. The resident bootstrap stays in the JVM while payloads, hosts and
modules are replaced. An incompatible bootstrap requires a game restart; see the
[save-bridge compatibility policy](save-bridge.md#compatibility-and-lifecycle)
for current runtime requirements. The app may also need restarting to use its own
updated files.

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

Continuous vehicle modules use a leased control session independently of backup
requests. Configuration changes apply at the vehicle's safe boundary without
replacing its classes. Desired and applied revisions distinguish a saved preference
from the configuration currently in use.

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

A disconnected request retains ownership of an admitted synchronous game save
until that call returns. Replacement never replays the save. Queued cancellation
and completion rules are defined in [save admission and failures](save-bridge.md#admission-and-failures).

## Verification boundary

The reload harness uses synthetic providers to test in-flight ownership, changed
archives, relocation, host/payload replacement and retirement failures. It also
checks WATCH epochs, stable identities, ticket invalidation and a single game-loop
hook. Vehicle tests add control-session ownership, settings revisions and cleanup.

Refer to harness/TRX and package checks for the build being used, and the
[vehicle test guide](e2e-vehicle-drivetrain.md) for live-game acceptance. Retirement
releases effects and references; it does not force the JVM to unload classes.
