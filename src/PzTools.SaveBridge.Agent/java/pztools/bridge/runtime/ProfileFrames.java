package pztools.bridge.runtime;

/**
 * The game loop's way to the profiler, and the only one. The per-frame callback (the state observer's, or the
 * recording's own when nothing observes) calls {@link #tick()} here, never the recorder: this class needs nothing but
 * the base module, so the recorder and the flight recorder behind it are loaded only once a recording starts.
 *
 * <p>Whatever the recorder throws ends the frame marks of that recording and nothing else: a game update that drops
 * the flight recorder from its Java runtime, or a fault inside it, must not take the state observer (and with it the
 * backups' timing) down with the profiler.
 */
final class ProfileFrames {
    private static volatile Runnable mark;
    private static volatile String failure = "";

    private ProfileFrames() { }

    /** A recording starts marking frames. */
    static void attach(Runnable value) { mark = value; failure = ""; }

    /** That recording stops marking; a newer one's mark is left alone. */
    static void detach(Runnable value) { if (mark == value) mark = null; }

    static boolean attached() { return mark != null; }

    /** Why the marks stopped by themselves, or empty. */
    static String failure() { return failure; }

    /** Game thread, once per frame. Two reads while no recording runs and no note waits. */
    static void tick() {
        // A note over the player for the app; it never throws into the frame.
        GameNotices.tick();
        Runnable current = mark;
        if (current == null) return;
        try { current.run(); }
        catch (Throwable thrown) {
            if (mark == current) mark = null;
            failure = thrown.getClass().getSimpleName();
            // Once, in the game's own log: the recording goes on without frames, everything else as before.
            System.err.println("[PzTools profiler] Frame marks stopped: " + thrown);
        }
    }
}
