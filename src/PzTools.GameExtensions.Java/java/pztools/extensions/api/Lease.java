package pztools.extensions.api;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * Admission and drain for calls into code that can be retired. A call acquires before it runs and
 * releases after; {@link #close} refuses new calls at once, and {@link #await} waits for the ones
 * already in flight. Retiring never holds a lock a call in flight needs.
 */
public final class Lease {
    private boolean closed;
    private int active;

    /** A lease that never admitted anything: awaiting it returns at once. */
    public static Lease closedLease() {
        var lease = new Lease();
        lease.close();
        return lease;
    }
    /** False once closed; otherwise the caller must {@link #release} exactly once. */
    public synchronized boolean acquire() {
        if (closed) return false;
        active++;
        return true;
    }
    public synchronized void release() { if (active > 0 && --active == 0) notifyAll(); }
    /** Any thread, never blocks: no new call is admitted from now on. */
    public synchronized void close() { closed = true; }
    /** Waits until no admitted call is still running; times out rather than waiting for ever. */
    public synchronized void await(long timeoutMillis) throws InterruptedException, TimeoutException {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        while (active != 0) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) throw new TimeoutException("Calls still in flight");
            TimeUnit.NANOSECONDS.timedWait(this, remaining);
        }
    }
}
