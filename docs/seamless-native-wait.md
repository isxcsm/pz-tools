# Private native-save completion

The old public save/stop rewrites were removed in 0.7 and are NOT reintroduced.
Module 0.9 uses a private save companion, read-only native phase observation and the
game's existing snapshot lock. See [current ownership and limits](game-extensions.md#private-native-completion-09).

The original native writer performs both original save calls. The game thread only
stops waiting early after the exact native phase starts and original-lock ownership
is secured. Public native save/stop bodies remain unchanged. Tests cover a preceding
pending-cell phase, a following normal save, stop, failed retry, world invalidation
and a worker exiting without acknowledgement. Real native C++/gameplay acceptance is
separate from these isolated Java tests.