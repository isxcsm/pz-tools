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
        samplingRounds();
        Path folder = Files.createTempDirectory("pztools-rolling");
        ClassLoader loader = ClassLoader.getSystemClassLoader();
        try {
            // Whatever the Lua sampler finds on this class path, the recording runs.
            String status = ProfileRecorder.startRolling(false, 10, loader);
            check(status.startsWith("rolling;") && status.contains(";general;"), "Not rolling: " + status);

            // Two bursts of frames 3 s apart. Each mark ends the frame before it. The window below is 2 s: the end of a save
            // is its last event, which a loaded machine can write a second or more after the last frame.
            for (int index = 0; index < 5; index++) { ProfileRecorder.frame(); Thread.sleep(20); }
            Thread.sleep(3000);
            for (int index = 0; index < 5; index++) { ProfileRecorder.frame(); Thread.sleep(20); }
            Path saved = folder.resolve("saved.jfr");
            long savedAt = System.currentTimeMillis();
            status = ProfileRecorder.save(saved);
            check(status.startsWith("rolling;"), "A save ended the rolling recording: " + status);
            check(Files.size(saved) > 0, "The save wrote nothing");

            // Whole, every frame ended so far; cut to the last two seconds, only those that began in the second burst.
            long[] all = ProfileExport.export(saved, folder.resolve("all.pzprof"), new HashMap<>(Map.of("mode", "general")));
            check(all[1] == 9, "Whole save: " + all[1] + " frames");
            var information = new HashMap<>(Map.of("mode", "general", "keepLastSeconds", "2"));
            long[] last = ProfileExport.export(saved, folder.resolve("last.pzprof"), information);
            check(last[1] == 4, "Last two seconds: " + last[1] + " frames");
            check(!information.containsKey("keepLastSeconds"), "The window was written as information");
            check(last[3] < 2_100_000, "The cut save is " + last[3] + " us long");
            // The same window from when the save was asked for, without a pass to find the end.
            var from = new HashMap<>(Map.of("mode", "general", "keepFromEpochMillis", Long.toString(savedAt - 2000)));
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

            // Each file back at its own mode: the general one cut to its period, the detailed one at its own pace.
            long general = busy(ProfileExport.export(both, folder.resolve("both.pzprof"), new HashMap<>(Map.of("mode", "general"))), folder.resolve("both.pzprof"));
            long detailed = busy(ProfileExport.export(asked, folder.resolve("asked.pzprof"), new HashMap<>(Map.of("mode", "detailed"))), folder.resolve("asked.pzprof"));
            // How finely the recorder really sampled depends on the machine (its load; whether Windows grants the 1 ms
            // timer): measured 400 to 880 of the busy thread's samples here, and once about 120. So each file is judged
            // against the samples taken, not a rate; samplingRounds() checks the cut itself.
            long taken = busySamples(asked);
            // A second and a half of busy code, cut to one round in each 10 ms: about 150 at most, as a Standard
            // recording alone would have.
            check(general > 0 && general <= 170, "General samples of the busy thread: " + general + " of " + taken + " taken");
            // The detailed file keeps its own pace: every round the recorder took.
            check(detailed >= taken * 95 / 100 && detailed <= taken, "Detailed samples of the busy thread: " + detailed + " of " + taken + " taken");
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

    /** The cut of samples to a file's period, on made-up times (microseconds): the same on any machine. */
    private static void samplingRounds() {
        // Rounds of two samples 30 us apart every 1.5 ms for 1.5 s, as when a Detailed recording runs beside.
        check(kept(new ProfileExport.SamplingRounds(10_000), 1_500, 1_000) == 300, "A 10 ms file keeps one round in each 10 ms");
        check(kept(new ProfileExport.SamplingRounds(1_000), 1_500, 1_000) == 2_000, "A 1 ms file keeps rounds 1.5 ms apart");
        // At the file's own pace, or slower (a coarse system timer), every round stays.
        check(kept(new ProfileExport.SamplingRounds(10_000), 10_500, 143) == 286, "A 10 ms file dropped rounds at its own pace");
        check(kept(new ProfileExport.SamplingRounds(1_000), 15_600, 96) == 192, "A 1 ms file dropped rounds of a coarse timer");
        // Rounds 1.5 ms apart with a 9 ms pause every 13 (a loaded machine): still about one in each 10 ms (a round after
        // a pause stays, at least 7.5 ms after the last), and never two kept rounds closer than half the period.
        var rounds = new ProfileExport.SamplingRounds(10_000);
        long time = 0, last = Long.MIN_VALUE;
        int keptRounds = 0;
        for (int round = 0; round < 1_000; round++) {
            time += round % 13 == 12 ? 9_000 : 1_500;
            if (!rounds.keep(time)) continue;
            check(last == Long.MIN_VALUE || time - last >= 5_000, "Two rounds kept " + (time - last) + " us apart");
            last = time; keptRounds++;
        }
        long slices = time / 10_000 + 1;
        check(keptRounds <= slices * 11 / 10 && keptRounds >= slices * 9 / 10, keptRounds + " rounds kept in " + slices + " slices");
    }

    private static int kept(ProfileExport.SamplingRounds rounds, long every, int count) {
        int result = 0;
        for (int round = 0; round < count; round++) {
            boolean first = rounds.keep(round * every), second = rounds.keep(round * every + 30);
            check(first == second, "A round was split at " + round * every);
            if (first) result += 2;
        }
        return result;
    }

    /** The busy thread's Java samples the recorder wrote into a file. */
    private static long busySamples(Path file) throws Exception {
        long count = 0;
        for (var event : jdk.jfr.consumer.RecordingFile.readAllEvents(file))
            if (event.getEventType().getName().equals("jdk.ExecutionSample") && event.getThread("sampledThread") != null
                    && "busy-test".equals(event.getThread("sampledThread").getJavaName())) count++;
        return count;
    }

    private static volatile double sink;

    /** A second and a half of Java code that never waits. */
    private static void spin() {
        long until = System.nanoTime() + 1_500_000_000L;
        double value = 0;
        while (System.nanoTime() < until) value += Math.sqrt(value + 1);
        sink = value;
    }

    /** The busy thread's Java samples in a converted file. */
    private static long busy(long[] counts, Path file) throws Exception {
        var lines = lines(file);
        String busy = null;
        for (String line : lines) if (line.startsWith("T\t") && line.endsWith("\tbusy-test")) busy = line.split("\t")[1];
        check(busy != null, "No busy thread in " + file.getFileName() + " (" + counts[0] + " samples)");
        long count = 0;
        for (String line : lines) {
            String[] fields = line.split("\t");
            if (fields[0].equals("S") && fields[2].equals(busy) && fields[4].equals("J")) count++;
        }
        return count;
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
