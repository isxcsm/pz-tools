package pztools.bridge.runtime;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;

/**
 * The rolling recording in a real flight recorder, without a game: it keeps going through a save, a save cut to its
 * last stretch holds only that, a recording asked for runs beside it, stopping either never stops the other, and each
 * file converts back to its own mode's sampling.
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
            long savedAt = System.currentTimeMillis();
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
            // The same window from when the save was asked for, without a pass to find the end.
            var from = new HashMap<>(Map.of("mode", "general", "keepFromEpochMillis", Long.toString(savedAt - 1000)));
            long[] fromAsked = ProfileExport.export(saved, folder.resolve("from.pzprof"), from);
            check(fromAsked[1] == 4, "From when asked: " + fromAsked[1] + " frames");
            check(!from.containsKey("keepFromEpochMillis"), "The window's start was written as information");

            // A recording asked for runs beside the rolling one, here in the finer mode: each reports itself, a save
            // takes the rolling one, and stopping either leaves the other.
            Path asked = folder.resolve("asked.jfr");
            status = ProfileRecorder.start(asked, true, 30, loader);
            check(status.startsWith("recording;") && status.contains(";detailed;"), "The asked recording did not start: " + status);
            expect(() -> ProfileRecorder.start(folder.resolve("again.jfr"), false, 30, loader), "already-recording");
            // Busy Java code for the sampler to find, while both run.
            var busy = new Thread(ProfileRollingTest::spin, "busy-test");
            busy.start();
            busy.join();
            Path both = folder.resolve("both.jfr");
            status = ProfileRecorder.save(both);
            check(status.startsWith("rolling;") && status.contains(";general;"), "A save beside the asked recording: " + status);
            check(ProfileRecorder.status().startsWith("recording;"), "Status no longer reports the asked recording");
            check(ProfileRecorder.stopRolling().startsWith("rolling;"), "A rolling stop did not report the rolling recording");
            check(ProfileRecorder.running() && ProfileRecorder.status().startsWith("recording;"), "A rolling stop ended the asked recording");
            check(ProfileRecorder.startRolling(false, 10, loader).startsWith("rolling;"), "Rolling could not start beside the asked recording");
            check(ProfileRecorder.stop().startsWith("recording;"), "The asked stop did not report the asked recording");
            check(ProfileRecorder.running() && ProfileRecorder.status().startsWith("rolling;"), "The asked stop ended the rolling recording");

            // Each file back at its own mode: the general one's busy samples a period apart, the detailed one's closer.
            long[] general = gaps(ProfileExport.export(both, folder.resolve("both.pzprof"), new HashMap<>(Map.of("mode", "general"))), folder.resolve("both.pzprof"));
            long[] detailed = gaps(ProfileExport.export(asked, folder.resolve("asked.pzprof"), new HashMap<>(Map.of("mode", "detailed"))), folder.resolve("asked.pzprof"));
            // A second and a half of busy code: about 150 samples at 10 ms, as a Standard recording alone would have.
            check(general[0] >= 90 && general[0] <= 200, "General samples of the busy thread: " + general[0]);
            check(detailed[0] > general[0] * 3, "Detailed " + detailed[0] + " against general " + general[0] + " busy samples");
            check(information(folder.resolve("both.pzprof"), "javaPeriodMicros").equals("10000"), "General period");
            check(information(folder.resolve("asked.pzprof"), "javaPeriodMicros").equals("1000"), "Detailed period");

            // Stopping the rolling one ends it.
            ProfileRecorder.startRolling(true, 10, loader);
            check(ProfileRecorder.stopRolling().startsWith("rolling;"), "Rolling stop did not report the rolling recording");
            check(ProfileRecorder.status().startsWith("idle;") && !ProfileRecorder.active(), "Still recording after the rolling stop");
            System.out.println("PASS: the rolling recording keeps its last stretch, beside a recording asked for");
        } finally {
            ProfileRecorder.closeQuietly();
            try (Stream<Path> files = Files.walk(folder)) {
                files.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete());
            }
        }
    }

    private static volatile double sink;

    /** A second and a half of Java code that never waits. */
    private static void spin() {
        long until = System.nanoTime() + 1_500_000_000L;
        double value = 0;
        while (System.nanoTime() < until) value += Math.sqrt(value + 1);
        sink = value;
    }

    /** The busy thread's Java samples in a converted file: how many, and the closest two (microseconds). */
    private static long[] gaps(long[] counts, Path file) throws Exception {
        var lines = lines(file);
        String busy = null;
        for (String line : lines) if (line.startsWith("T\t") && line.endsWith("\tbusy-test")) busy = line.split("\t")[1];
        check(busy != null, "No busy thread in " + file.getFileName() + " (" + counts[0] + " samples)");
        var times = new java.util.ArrayList<Long>();
        for (String line : lines) {
            String[] fields = line.split("\t");
            if (fields[0].equals("S") && fields[2].equals(busy) && fields[4].equals("J")) times.add(Long.parseLong(fields[1]));
        }
        times.sort(null);
        long closest = Long.MAX_VALUE;
        for (int index = 1; index < times.size(); index++) closest = Math.min(closest, times.get(index) - times.get(index - 1));
        return new long[] { times.size(), closest };
    }

    private static String information(Path file, String key) throws Exception {
        for (String line : lines(file)) if (line.startsWith("I\t" + key + "\t")) return line.split("\t")[2];
        return "";
    }

    private static java.util.List<String> lines(Path file) throws Exception {
        try (var input = new java.util.zip.GZIPInputStream(Files.newInputStream(file))) {
            return new String(input.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).lines().toList();
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
