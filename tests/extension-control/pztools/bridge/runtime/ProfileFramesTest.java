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
        // The state observer's per-frame callback, composed as RuntimeObserver composes it.
        var observed = new AtomicInteger();
        Runnable observer = RuntimeObserver.perFrame(observed::incrementAndGet);

        // No recording: the profiler is never reached.
        observer.run();
        check(observed.get() == 1, "Idle observer did not run");

        // A recording's frame mark that fails as the real one would here: its event type cannot load without the
        // flight recorder. Any failure inside the recorder during a recording takes the same path.
        Runnable recorder = () -> new ProfileRecorder.FrameEvent().begin();
        ProfileFrames.attach(recorder);
        observer.run();
        check(observed.get() == 2, "The recorder's failure stopped the state observer");
        check(!ProfileFrames.attached(), "A failed frame mark stayed attached");
        check(ProfileFrames.failure().equals("NoClassDefFoundError"), "Unexpected failure: " + ProfileFrames.failure());
        observer.run();
        check(observed.get() == 3, "The observer stopped after the profiler failed");

        // The observer stopping asks the relay, not the recorder.
        ProfileControl.observerStopped();

        // A recording detaches only its own mark.
        var marks = new AtomicInteger();
        Runnable mark = marks::incrementAndGet;
        ProfileFrames.attach(mark);
        ProfileFrames.detach(recorder);
        observer.run();
        check(marks.get() == 1 && ProfileFrames.attached(), "Another recording's detach removed this mark");
        ProfileFrames.detach(mark);
        check(!ProfileFrames.attached(), "Detach left the mark attached");
        // The app's notes ride the same relay and need nothing beyond the base module either.
        check(GameNotices.compose("en-US", new String[] { "saved-last:2", "busy" }).equals("Saved the last 2 min · PZ Tools is busy with other work"),
            "Unexpected note");
        observer.run();
        check(observed.get() == 5, "A note check stopped the observer");
        System.out.println("PASS: profiler failures stay in the profiler");
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
