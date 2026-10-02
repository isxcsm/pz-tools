package pztools.bridge.runtime;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;

/**
 * The rolling recording in a real flight recorder, without a game: it keeps going through a save, a save cut to its
 * last stretch holds only that, a recording asked for replaces it, and stopping it never stops someone else's.
 */
public final class ProfileRollingTest {
    private ProfileRollingTest() { }

    public static void main(String[] args) throws Exception {
        Path folder = Files.createTempDirectory("pztools-rolling");
        ClassLoader loader = ClassLoader.getSystemClassLoader();
        try {
            // Whatever the Lua sampler finds on this class path, the recording runs.
            String status = ProfileRecorder.startRolling(false, 10, loader);
            check(status.startsWith("rolling;") && status.contains(";general;"), "Not rolling: " + status);

            // Two bursts of frames 1.5 s apart. Each mark ends the frame before it.
            for (int index = 0; index < 5; index++) { ProfileRecorder.frame(); Thread.sleep(20); }
            Thread.sleep(1500);
            for (int index = 0; index < 5; index++) { ProfileRecorder.frame(); Thread.sleep(20); }
            Path saved = folder.resolve("saved.jfr");
            status = ProfileRecorder.save(saved);
            check(status.startsWith("rolling;"), "A save ended the rolling recording: " + status);
            check(Files.size(saved) > 0, "The save wrote nothing");

            // Whole, every frame ended so far; cut to the last second, only those that began in the second burst.
            long[] all = ProfileExport.export(saved, folder.resolve("all.pzprof"), new HashMap<>(Map.of("mode", "general")));
            check(all[1] == 9, "Whole save: " + all[1] + " frames");
            var information = new HashMap<>(Map.of("mode", "general", "keepLastSeconds", "1"));
            long[] last = ProfileExport.export(saved, folder.resolve("last.pzprof"), information);
            check(last[1] == 4, "Last second: " + last[1] + " frames");
            check(!information.containsKey("keepLastSeconds"), "The window was written as information");
            check(last[3] < 1_100_000, "The cut save is " + last[3] + " us long");

            // A recording asked for replaces the rolling one; while it runs rolling cannot take over, and neither a
            // rolling stop nor a save touches it.
            status = ProfileRecorder.start(folder.resolve("asked.jfr"), false, 5, loader);
            check(status.startsWith("recording;"), "The asked recording did not start: " + status);
            expect(() -> ProfileRecorder.startRolling(false, 10, loader), "already-recording");
            expect(() -> ProfileRecorder.save(folder.resolve("other.jfr")), "not-rolling");
            check(ProfileRecorder.stopRolling().startsWith("recording;"), "A rolling stop ended the asked recording");
            check(ProfileRecorder.running(), "The asked recording stopped");
            ProfileRecorder.stop();

            // Stopping the rolling one ends it.
            ProfileRecorder.startRolling(true, 10, loader);
            check(ProfileRecorder.stopRolling().startsWith("rolling;"), "Rolling stop did not report the rolling recording");
            check(ProfileRecorder.status().startsWith("idle;"), "Still recording after the rolling stop");
            System.out.println("PASS: the rolling recording keeps its last stretch");
        } finally {
            ProfileRecorder.closeQuietly();
            try (Stream<Path> files = Files.walk(folder)) {
                files.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete());
            }
        }
    }

    private interface Action { void run() throws Exception; }

    private static void expect(Action action, String code) throws Exception {
        try { action.run(); } catch (IllegalStateException state) {
            check(code.equals(state.getMessage()), "Expected " + code + ", got " + state.getMessage());
            return;
        }
        throw new AssertionError("Expected " + code);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
