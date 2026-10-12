package pzext.api;

import java.util.concurrent.TimeUnit;

/** When a grid works its networks out again: once a second, and at the next frame after something changed. */
final class Cadence {
    private static final long PERIOD_NANOS = TimeUnit.SECONDS.toNanos(1);
    // Set by a change, also by a hook on another thread; the next frame works the networks out.
    private volatile boolean changed = true;
    // Due at the first frame. (Long.MIN_VALUE would overflow the difference: never due.)
    private long ranAt = System.nanoTime() - PERIOD_NANOS;

    void changed() { changed = true; }

    /** Whether the frame at {@code now} works the networks out: a second has passed, or something changed. */
    boolean due(long now) {
        boolean second = now - ranAt >= PERIOD_NANOS;
        if (!second && !changed) return false;
        changed = false;
        if (second) ranAt = now;
        return true;
    }
}
