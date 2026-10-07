package pztools.bridge.runtime;

import java.util.concurrent.atomic.AtomicInteger;

/**
 * Run in a JVM without the flight recorder (--limit-modules java.base,java.instrument), as a game whose Java runtime
 * an update left without it: the profiler fails, and only the profiler.
 */
public final class ProfileFramesTest {
    private ProfileFramesTest() { }

    public static void main(String[] args) {
        check(ModuleLayer.boot().findModule("jdk.jfr").isEmpty(), "Run this test without the jdk.jfr module");
        // The state observer's per-frame job, and the profiler's beside it, in the frame router.
        var observed = new AtomicInteger();
        Object observer = new Object();
        check(Frames.add(Frames.Job.OBSERVER, observer, observed::incrementAndGet), "Observer job refused");
        check(Frames.add(Frames.Job.PROFILE, ProfileFrames.class, ProfileFrames::tick), "Profiler job refused");

        // No recording: the profiler is never reached.
        Frames.run();
        check(observed.get() == 1, "Idle observer did not run");

        // A recording's frame mark that fails as the real one would here: its event type cannot load without the
        // flight recorder. Any failure inside the recorder during a recording takes the same path.
        Runnable recorder = () -> new ProfileRecorder.FrameEvent().begin();
        ProfileFrames.attach(recorder);
        Frames.run();
        check(observed.get() == 2, "The recorder's failure stopped the state observer");
        check(!ProfileFrames.attached(), "A failed frame mark stayed attached");
        check(ProfileFrames.failure().equals("NoClassDefFoundError"), "Unexpected failure: " + ProfileFrames.failure());
        Frames.run();
        check(observed.get() == 3, "The observer stopped after the profiler failed");

        // A recording detaches only its own mark.
        var marks = new AtomicInteger();
        Runnable mark = marks::incrementAndGet;
        ProfileFrames.attach(mark);
        ProfileFrames.detach(recorder);
        Frames.run();
        check(marks.get() == 1 && ProfileFrames.attached(), "Another recording's detach removed this mark");
        ProfileFrames.detach(mark);
        check(!ProfileFrames.attached(), "Detach left the mark attached");

        // The app's notes have a job of their own, which needs nothing beyond the base module either.
        check(GameNotices.compose("en-US", new String[] { "saved-last:2", "busy" }).equals("Saved the last 2 min · PZ Tools is busy with other work"),
            "Unexpected note");
        check(Frames.add(Frames.Job.NOTICES, GameNotices.class, GameNotices::tick), "Notes job refused");
        Frames.run();
        check(observed.get() == 5, "A note check stopped the observer");
        Frames.remove(Frames.Job.NOTICES, GameNotices.class);
        Frames.remove(Frames.Job.PROFILE, ProfileFrames.class);
        Frames.remove(Frames.Job.OBSERVER, observer);
        System.out.println("PASS: profiler failures stay in the profiler");
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
