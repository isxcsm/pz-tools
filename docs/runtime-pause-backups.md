# Game-aware backup timing

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

Automatic (periodic) backups run at a fixed interval. With game-aware timing, that
interval counts only time you actually play: while the game is paused or your character
is asleep, the countdown stops and picks up where it left off when you play again. This
page is for anyone who wonders why the countdown stopped, why a backup came later than
expected, or why a backup ran without a game save.

The setting is **Delay scheduled backups while paused or asleep**
(`[backup].pause_periodic_during_game`), on by default. PZ Tools reads pause and sleep
from the running game through the [save bridge](glossary.md#save-bridge); it does not
guess them from which files the game has open.

## What you see

With a five-minute interval, pausing after two minutes leaves three minutes, and they
run once you resume. Sleeping holds the remaining time the same way. The countdown
follows real time: a faster game speed does not make it run faster.

| Game state | Periodic countdown |
| --- | --- |
| One active local world; player awake and game unpaused | Advances |
| Paused or asleep | Holds the remaining time |
| A debug-mode tool open on top of the game (the chunk viewer, for example) | Holds, like a pause: the world stays loaded and game time stands still |
| Sleep cannot be read (pause can) | Advances; only the sleep pause is lost |
| Played character is dead | Holds until a new character is played (see [death backups](runtime-character-death.md)) |
| Game still starting up, loading, ambiguous processes, or a briefly unknown or [stale](glossary.md#observation-fresh-stale) state | Holds; does not assume active play |
| Game cannot be read for about 90 seconds | Falls back to the wall clock (see [below](#when-the-game-cannot-be-read)) |
| Confirmed main menu or game exit | Clears the world [target](glossary.md#active-save-target) |

The footer tells a fresh main-menu reading apart from loading or no game process. A
stale connection is not labelled "Game is not running." A held countdown keeps its
remaining value, and its display follows the system's animation preference.

## Settings and what restarts the countdown

- **Turning the setting off** selects wall-clock scheduling: backups run at every
  interval, paused or not. It does not stop the shared game-state reading used by the
  [game extensions](game-extensions.md) and other game-state features.
- **Turning Save game before backup off** also leaves that reading on. A pause-aware
  periodic backup then uses a guarded check to confirm the backup is allowed
  ([admission](glossary.md#admission)) without saving the game. See
  [saving the game before a backup](save-bridge.md).
- **Automatic backups switched off** wins over either timing choice. Manual and death
  backups follow their own rules.
- **Changing the interval or the timing setting** starts a new interval. Restarting
  the app also starts periodic timing afresh. A reconnect to the game keeps the
  countdown where it was.
- **Missed intervals** do not cause a burst of catch-up saves.

## When the game cannot be read

Each game-dependent feature stops only when what it needs is missing; backups
themselves never depend on the game. A game update, a blocked attach helper or an
unrecognised game state must not end backups silently.

| What is missing | What happens |
| --- | --- |
| **Observation lost**: the connection is failing, stale, or answering without a recognisable game state, for longer than the grace period (about 90 seconds) | Periodic backups follow the wall clock at the configured interval. The target is the save the game's file locks point at, and each backup runs only while that save is still in use. They are ordinary unguarded backups. When the game can be read again, scheduling returns to game time. |
| **Save request unreachable**: the helper cannot start or attach, the connection times out, or the bridge is missing or too old | Nothing was asked of the game, so the backup goes ahead with the files as they are on disk and records a warning. This applies to manual, periodic and death backups. |
| **Sleep unreadable** | The clock keeps running; pausing still holds it. |

A game that is still starting up is not a lost observation, however long it takes. Its
state is read once per frame of the game's main loop, which first runs after the
initial load; until then the connection is up but no state has been read yet. A game
that runs but whose state cannot be read is told apart within a fraction of a second,
because its frames report the unreadable state.

A save the game refused, reported as failed, or left unanswered after the command was
sent still fails; see the next section.

While the connection is lost, the app shows one card for it, the schedule line says
backups run without a game save, and the settings that need the game are locked until
the connection returns. Their saved values are kept. The card suggests restarting the
game only when that is known to help: the game still runs the bridge from before a PZ
Tools update. A game version this PZ Tools cannot read stays unreadable after a
restart, and backups keep running without a game save.

## When a backup attempt fails

**The outcome is known.** A failure with a known game-save outcome ends that attempt,
and the next interval tries again. This covers an error the game reported, a worker
that could not start, and a capture that failed after the save returned. A save
command that could not be sent at all is not a failure: the backup goes ahead without
it, as described above.

**The outcome is unknown.** The save command was sent and no usable answer came back,
a dispatched worker's result is missing or malformed, or the attempt was cancelled. The
game may still be saving, so the attempt is not retried at once. The scheduler sits out
one full interval of active play and then resumes by itself; the footer shows the
remaining time. The uncertain result survives a scheduler restart.

**Not unknown.** An error before any worker was dispatched, a worker that did nothing
(`Skipped`), and a reservation that never reached its worker keep the slot, and it is
tried again. See [save-bridge behaviour](save-bridge.md#admission-and-failures).

**Background processes.** Extension control runs beside the game-state reading and
cannot end it. An extension-controller failure is reported and retried on its own. With
the extension switched off, a failed OFF confirmation is recorded as informational and
is not retried for that world. The scheduler processes are restarted with backoff,
reported as faulted after repeated quick failures, and still retried about once a
minute.

## How it works inside

### Save admission

The countdown in the app is only a display; it does not permit a backup. The scheduler
issues a [ticket](glossary.md#ticket) for a specific process, world and timing
generation. Immediately before saving, the game thread checks identity, pause, sleep
and the active time that is due once more.

If a setting changes while preparation is queued, cancellation and admission go
through the same state transition, and only one of them wins. If cancellation wins,
the backup is deferred without using up its periodic slot or creating a
[revision](glossary.md#revision-backup). A save that has already started completes
normally. Files are captured only after successful preparation.

### Reading the game state

The game thread samples its state through the shared dispatcher. A snapshot is made on
a meaningful change or at 100 ms checkpoints, and snapshots are sent every 250 ms;
transport and SQLite work stay off the game thread. An unknown interval, or a gap
longer than two seconds, breaks the run of active time instead of counting that time
as play.

The [WATCH](glossary.md#watch) stream sends only the latest value, so it carries the
cumulative active time and [epoch](glossary.md#observer-epoch) identifiers. That way a
pause and resume are not lost when updates are merged. How recently a message arrived
and how recently the game took its sample are checked separately: a live socket cannot
make a stalled game thread look current. After a reconnect, the saved remainder is
anchored again.

| Layer | Responsibility |
| --- | --- |
| Java adapter and observer | Read game state, maintain world/clock identity and cumulative active time |
| SaveBridge / State.Scheduler | Authenticate the stream, reconnect and publish observations |
| Zomboid.State | Commit semantic transitions and an idempotent [outbox](glossary.md#collector-reactor-projection-outbox) |
| Scheduling | Own remaining time, policy generation and admission tickets |
| Projections / WinUI | Display immutable status without controlling admission |

The database is written on meaningful transitions and slower checkpoints, not every
frame. Whether the character is alive, as read from the game, is kept apart from the
state saved in `players.db`; see [death backups](runtime-character-death.md).

## Updates and verification

Use app, worker and bridge files from the same build.
[Component updates](module-reload.md) explains compatible updates and when a
[bootstrap](glossary.md#bootstrap) already in the game requires a game restart. Game
state reading needs no reset of the repository or the save.

Tests with a controlled clock, temporary databases and a synthetic game JVM cover
pause and sleep, reconnects, cancellation, settings changes and save-before-capture.
They do not establish real-game frame time, long-session behaviour or compatibility
with every mod. Use a disposable world for those acceptance checks.
