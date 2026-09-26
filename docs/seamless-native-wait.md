# Native wait optimization — retired

[Current private save design](game-extensions.md)

The experimental 0.5/0.6 implementation rewrote MapCollisionData.save/stop and
ordinary-save fences to permit an outstanding native write. That implementation
is removed in 0.7: it does not meet the requirement to preserve normal/mod saving.
The private save entry currently calls the original native save and waits normally.
Future native optimization must own an isolated snapshot/completion boundary without
rewriting ordinary saving or teardown. Restart the game to remove older loaded hooks.
