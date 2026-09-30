package pztools.extensions.runtime.input;

import java.util.concurrent.locks.LockSupport;

/** Where key state comes from. Called only on the timeline's own thread; must not touch game state. */
public interface KeyStateSource {
    /** Whether the physical key is down right now, by platform virtual-key code. */
    boolean down(int virtualKey) throws Throwable;
    /** Whether this process owns the foreground window. Keys held for another program are not input. */
    boolean focused() throws Throwable;
    /**
     * Waits between two polls. The JVM's own short waits are not dependable on every platform
     * (on Windows they fall back to the 15 ms system tick), so a source may bring a better one.
     */
    default void pause(long nanos) throws Throwable { LockSupport.parkNanos(this, nanos); }
    /** The clock the held time is measured with; monotonic nanoseconds. */
    default long nanoTime() { return System.nanoTime(); }
    /** Timeline thread, once, when it stops: release whatever the source holds. */
    default void release() throws Throwable { }
}
