package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;

/**
 * The payload's frame router (docs/design/game-bridge.md#the-game-loop-hook): the one per-frame callback the bootstrap
 * runs for the payload, and the jobs it runs each frame on the game thread, in a fixed order. A job is held by its
 * owner until the owner lets go; the router holds the bootstrap's frame slot while any job is held, and gives it back
 * with the last one, which is what a payload switch waits for. A new per-frame job is added here, never in the
 * bootstrap.
 *
 * <p>Each job runs on its own: whatever one throws drops that job (its owner still holds it) and leaves the others.
 */
final class Frames {
    /** The jobs, in the order they run each frame. */
    enum Job {
        /** The profiler's frame marks, first, so that a frame's mark covers all the work in it. */
        PROFILE,
        /** The extension API's per-frame work ({@code GameApi.frame}), in a game the startup loader started. */
        API,
        /** A note over the player the app asked for. */
        NOTICES,
        /** The state observer's sample, which WATCH streams. */
        OBSERVER,
        /** The extension lifecycle: the poll of the extension control session that holds the extensions. */
        LIFECYCLE
    }

    private static final Job[] JOBS = Job.values();
    // Guarded by lock, which is taken after the owners' own locks and before the bootstrap's.
    private static final Object lock = new Object();
    private static final Object[] owners = new Object[JOBS.length];
    private static final Runnable[] work = new Runnable[JOBS.length];
    // What the game thread runs: a copy, replaced whole on each change, so that a frame takes no lock.
    private static volatile Runnable[] running = new Runnable[JOBS.length];
    private static final Runnable ROUTER = Frames::run;
    // Game thread only: the frame being run, for reads shared within one frame (PzRuntimeAdapter).
    private static long frame;
    private static Thread inFrame;

    private Frames() { }

    /**
     * Gives the job to the owner, or tells it the job is someone else's. False also while a payload switch waits for
     * the old payload to let go: the owner tries again later.
     */
    static boolean add(Job job, Object owner, Runnable task) {
        synchronized (lock) {
            int index = job.ordinal();
            if (owners[index] != null && owners[index] != owner) return false;
            if (!AgentEntry.claimFrames(ROUTER)) return false;
            owners[index] = owner;
            work[index] = task;
            running = work.clone();
            return true;
        }
    }

    /** The owner lets go of the job; with the last job, the router gives back the bootstrap's slot. */
    static void remove(Job job, Object owner) {
        synchronized (lock) {
            int index = job.ordinal();
            if (owners[index] != owner) return;
            owners[index] = null;
            work[index] = null;
            running = work.clone();
            for (Object other : owners) if (other != null) return;
            AgentEntry.releaseFrames(ROUTER);
        }
    }

    static boolean holds(Job job, Object owner) {
        synchronized (lock) { return owners[job.ordinal()] == owner; }
    }

    /** One frame, on the game thread. */
    static void run() {
        Runnable[] jobs = running;
        frame++;
        inFrame = Thread.currentThread();
        try {
            for (int index = 0; index < jobs.length; index++) {
                Runnable job = jobs[index];
                if (job == null) continue;
                try { job.run(); }
                catch (Throwable failure) { drop(index, job, failure); }
            }
        } finally { inFrame = null; }
    }

    /** Stops running a job that threw; its owner keeps it until it lets go. */
    private static void drop(int index, Runnable job, Throwable failure) {
        synchronized (lock) {
            if (work[index] != job) return;
            work[index] = null;
            running = work.clone();
        }
        System.err.println("[PzTools frames] " + JOBS[index] + " stopped: " + failure);
    }

    /**
     * The frame the calling thread is running, or -1 outside one (a call from a request's game-thread work or from a
     * test): what was read in this frame may be read again for the same frame.
     */
    static long current() { return inFrame == Thread.currentThread() ? frame : -1; }
}
