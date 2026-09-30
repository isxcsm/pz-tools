package pztools.extensions.runtime.input;

import java.util.Objects;

/**
 * How long keys were really held, measured off the game thread.
 *
 * <p>The game samples the keyboard once per frame, so a tap is rounded to whole frames and the same
 * tap gives a different result from one press to the next. A timeline polls the keys about once a
 * millisecond on its own daemon thread and keeps running totals. A consumer on the game thread
 * reads the totals once per frame; the difference from its previous reading is the time each key
 * was actually held during that frame, independent of the frame rate.
 *
 * <p>It only measures. It never injects, consumes or hooks input, and it knows nothing about the
 * game: what a key means, and whether the game currently accepts it, stays with the consumer.
 * One timeline belongs to one owner, which must close it; closing stops the thread.
 */
public final class KeyTimeline implements AutoCloseable {
    /** Requested wait between polls; timers round up, so the real interval is about a millisecond. */
    public static final long DEFAULT_POLL_NANOS = 500_000L;
    /** A longer gap between two polls means the thread was starved and that stretch is a guess. */
    public static final long DEFAULT_TOLERANCE_NANOS = 5_000_000L;
    public static final int MAXIMUM_KEYS = 32;

    /** Caller-owned buffer so a per-frame reading allocates nothing. */
    public static final class Reading {
        /** Observed time in nanoseconds since the timeline started; only differences are meaningful. */
        public long clock;
        /** Part of {@link #clock} spent in gaps longer than the tolerance. */
        public long unreliable;
        /** Per key, in the order given to {@link KeyTimeline#start}: total nanoseconds held. */
        public final long[] held;
        /** Bit i is set when key i was down at the latest poll. */
        public int downMask;
        public Reading(int keys) { held = new long[keys]; }
    }

    private final KeyStateSource source;
    private final int[] keys;
    private final long pollNanos, toleranceNanos;
    private final Thread thread;
    private final long[] held;
    private final boolean[] down;
    private long clock, unreliable;
    private int downMask;
    // Sequence lock: odd while the single writer is between its two increments.
    private volatile long version;
    private volatile boolean closed;
    private volatile String failure;

    private KeyTimeline(KeyStateSource source, int[] keys, long pollNanos, long toleranceNanos, String name) {
        this.source = source; this.keys = keys; this.pollNanos = pollNanos; this.toleranceNanos = toleranceNanos;
        held = new long[keys.length]; down = new boolean[keys.length];
        thread = new Thread(this::run, name);
        thread.setDaemon(true);
        thread.setPriority(Thread.MAX_PRIORITY);
    }

    public static KeyTimeline start(KeyStateSource source, int[] virtualKeys) {
        return start(source, virtualKeys, DEFAULT_POLL_NANOS, DEFAULT_TOLERANCE_NANOS);
    }

    public static KeyTimeline start(KeyStateSource source, int[] virtualKeys, long pollNanos, long toleranceNanos) {
        Objects.requireNonNull(source); Objects.requireNonNull(virtualKeys);
        if (virtualKeys.length == 0 || virtualKeys.length > MAXIMUM_KEYS) throw new IllegalArgumentException("1.." + MAXIMUM_KEYS + " keys");
        if (pollNanos < 100_000L || pollNanos > 50_000_000L || toleranceNanos < pollNanos)
            throw new IllegalArgumentException("invalid poll interval or tolerance");
        var timeline = new KeyTimeline(source, virtualKeys.clone(), pollNanos, toleranceNanos, "PzTools key timeline");
        timeline.thread.start();
        return timeline;
    }

    public int keyCount() { return keys.length; }
    public int virtualKey(int index) { return keys[index]; }
    /** Null while measuring; otherwise why it stopped. A stopped timeline's totals no longer advance. */
    public String failure() { return failure; }
    public boolean running() { return !closed && failure == null && thread.isAlive(); }

    /**
     * Any thread. Copies one consistent set of totals; false when none could be taken or the
     * timeline has stopped, in which case the caller must use its ordinary input instead.
     */
    public boolean read(Reading out) {
        if (out.held.length != keys.length) throw new IllegalArgumentException("reading size");
        if (failure != null || closed) return false;
        // The writer's update is a few additions; a bounded spin outlasts it unless it lost its CPU.
        for (int attempt = 0; attempt < 2000; attempt++) {
            long before = version;
            if ((before & 1) != 0) { Thread.onSpinWait(); continue; }
            out.clock = clock; out.unreliable = unreliable; out.downMask = downMask;
            System.arraycopy(held, 0, out.held, 0, held.length);
            if (before == version) return true;
        }
        return false;
    }

    private void run() {
        try {
            long previous = source.nanoTime();
            long[] credit = new long[keys.length];
            boolean focused = source.focused();
            for (int i = 0; i < keys.length; i++) down[i] = focused && source.down(keys[i]);
            while (!closed) {
                source.pause(pollNanos);
                long now = source.nanoTime(), elapsed = Math.max(0, now - previous);
                previous = now;
                focused = source.focused();
                int mask = 0;
                for (int i = 0; i < keys.length; i++) {
                    boolean current = focused && source.down(keys[i]);
                    // The change happened somewhere inside the interval; the midpoint has no bias.
                    credit[i] = current && down[i] ? elapsed : current != down[i] ? elapsed / 2 : 0;
                    down[i] = current;
                    if (current) mask |= 1 << i;
                }
                // Publish only plain arithmetic: a reader never waits on a system call.
                version++;
                clock += elapsed;
                if (elapsed > toleranceNanos) unreliable += elapsed;
                for (int i = 0; i < keys.length; i++) held[i] += credit[i];
                downMask = mask;
                version++;
            }
        } catch (Throwable stopped) {
            if ((version & 1) != 0) version++;
            failure = stopped.getClass().getSimpleName() + (stopped.getMessage() == null ? "" : ":" + stopped.getMessage());
        } finally {
            try { source.release(); } catch (Throwable ignored) { }
        }
    }

    /** Any thread, never blocks: the measuring thread ends at its next poll, a millisecond or so away. */
    public void stop() { closed = true; }

    /** Any thread. Stops the measuring thread; waits briefly so an owner can retire cleanly. */
    @Override public void close() {
        closed = true;
        if (Thread.currentThread() != thread) {
            try { thread.join(200); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }
    }
}
