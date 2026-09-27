# Game-aware backup timing

[Documentation index](README.md) · [User guide](../README.md)

Periodic backups normally count active play time, not time spent paused or asleep. The existing JVM observer supplies this state; file-sharing checks are not used to infer pause.

## User behavior

`[backup].pause_periodic_during_game` defaults to `true`. With a five-minute interval, pausing after two minutes leaves three minutes to run after resume. Sleeping also holds the remaining time. Faster game speed does not accelerate this real-time clock.

| Game state | Periodic countdown |
| --- | --- |
| One active local world; player awake and game unpaused | Advances |
| Paused or asleep | Holds the remaining time |
| Loading, unknown/stale state, disconnected observation or ambiguous processes | Holds; does not assume active play |
| Confirmed main menu or game exit | Clears the world target |

The footer distinguishes a fresh main-menu observation from loading or an absent process. A stale connection is not labeled "Game is not running." Held countdowns retain their remaining value and respect the system's animation preference.

Turning this setting off selects wall-clock scheduling. It does not stop the shared observer used by extensions and other game-state features. Turning **Save game before backup** off also leaves observation enabled. Pause-aware periodic backups then use a guarded probe to check admission without saving the game.

Automatic-backup enablement takes precedence over either timing policy. Manual and death-triggered work follow their own rules. Changing the interval or timing policy starts a new interval; restarting the app also rearms periodic timing. An observer reconnect preserves the checkpoint. Missed intervals do not cause a burst of catch-up saves.

## Save admission

The UI displays the countdown; it does not authorize a backup. The scheduler issues a ticket for a specific process, world and timing generation. Immediately before saving, the game thread rechecks identity, pause, sleep and the due active time.

If a setting changes while preparation is queued, cancellation competes with admission through the same state transition. Cancellation that wins defers the backup without consuming its periodic slot or creating a revision. A save that has already started completes normally. Capture follows only successful preparation.

A failed or missing completion is not replayed automatically. The scheduler preserves the uncertain result across recovery and blocks implicit retry for that generation. Check the result before turning automatic backups off and on to start a new interval. See [save-bridge behavior](save-bridge.md).

## Observation and ownership

The game thread samples state through the shared dispatcher. Snapshots are created on meaningful changes or 100ms checkpoints and sent at 250ms intervals; transport and SQLite work stay off the game thread. Unknown intervals or a gap longer than two seconds break active-time continuity instead of charging that time as play.

The latest-value stream carries cumulative active time and epoch identifiers. This lets pause/resume survive coalesced updates. Receipt freshness and game-sample freshness are checked separately: a live socket cannot make a stalled game thread current. Reconnection reanchors the saved remainder.

| Layer | Responsibility |
| --- | --- |
| Java adapter and observer | Read game state, maintain world/clock identity and cumulative active time |
| SaveBridge / State.Scheduler | Authenticate the stream, reconnect and publish observations |
| Zomboid.State | Commit semantic transitions and an idempotent outbox |
| Scheduling | Own remaining time, policy generation and admission tickets |
| Projections / WinUI | Display immutable status without controlling admission |

Database writes follow semantic transitions and slower checkpoints, not every frame. Live character-death identity is separate from the saved `players.db` state; see [death-triggered backups](runtime-character-death.md).

## Compatibility and tests

Deploy matching app, worker and bridge files. [Component reload](module-reload.md) explains compatible updates and when a resident bootstrap requires a game restart; no repository or save reset is needed for observation.

Controlled-clock, temporary-database and synthetic-JVM tests cover pause/sleep, reconnects, cancellation, settings changes and save-before-capture. They do not establish real-game frame time, long-session behavior or compatibility with every mod. Use a disposable world for those acceptance checks.
