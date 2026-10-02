package pztools.bridge.runtime;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.zip.GZIPOutputStream;
import jdk.jfr.consumer.*;

/**
 * Turns a flight recording into the compact text form the app reads. Runs in the helper JVM,
 * outside the game: parsing a recording is work the game should not be doing.
 *
 * <p>One record per line, tab separated, gzip compressed. Times are microseconds relative to the
 * first event read, in no particular order. Stacks and method names are written once and referred to by number, because the same
 * few hundred stacks make up almost every sample.
 * <pre>
 *   PZPROF 1
 *   I  key value                      information
 *   T  thread name                    a sampled thread
 *   M  id label                       a Java method, "package.Class.method"
 *   K  id m m m ...                   a Java stack, innermost first
 *   S  time thread stack state        a sample; state J = running Java, N = inside a native call
 *   F  time duration                  one game frame
 *   LM id name file                   a Lua function
 *   LK id f:line f:line ...           a Lua stack, innermost first
 *   L  time stack                     a Lua sample
 *   LA time bytes                     what the game thread allocated since the sampler's previous look,
 *                                     for the Lua sample at the same time
 *   LH time taken inLua periodMicros  Lua sampler totals since the previous LH
 *   GA time bytes                     what the game thread allocated since the previous GA, in Lua or not
 *
 * LA and GA are records of their own, not extra fields of L and LH, so a reader that predates them
 * still reads the samples; only recordings whose runtime has the per-thread counter carry them.
 *   G  time duration name cause       a garbage collection; duration is its total pause
 *   P  time duration kind thread detail   a pause or wait on one thread
 *   H  time used committed max        the Java heap in bytes, four times a second
 *   V  time dedicated shared          the game's video memory in bytes; added afterwards by the
 *                                     recording worker, which reads it from outside the game
 * </pre>
 */
public final class ProfileExport {
    private static final int MAXIMUM_DEPTH = 64;
    private ProfileExport() { }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) throw new IllegalArgumentException("Expected <recording.jfr> <output> [key=value ...]");
        Path input = Path.of(args[0]).toAbsolutePath(), output = Path.of(args[1]).toAbsolutePath();
        Path staged = output.resolveSibling(output.getFileName() + ".tmp");
        // What only the caller knows (recording mode, tool version) travels as plain information lines.
        var information = new LinkedHashMap<String, String>();
        for (int index = 2; index < args.length; index++) {
            int split = args[index].indexOf('=');
            if (split <= 0 || !args[index].substring(0, split).matches("[A-Za-z][A-Za-z0-9]{0,39}"))
                throw new IllegalArgumentException("Invalid information argument");
            information.put(args[index].substring(0, split), args[index].substring(split + 1));
        }
        long[] counts = export(input, staged, information);
        Files.move(staged, output, StandardCopyOption.REPLACE_EXISTING);
        System.out.println("EXPORTED\t" + counts[0] + "\t" + counts[1] + "\t" + counts[2] + "\t" + counts[3]);
    }

    /**
     * Returns {samples, frames, luaSamples, durationMicros}. With {@code keepLastSeconds} in the information (taken out
     * of it), only the events that start in that many seconds before the recording's last are kept: a rolling
     * recording holds more than its window, as it drops old data a whole chunk at a time.
     */
    static long[] export(Path input, Path output, Map<String, String> information) throws IOException {
        String keep = information.remove("keepLastSeconds");
        Instant cutoff = null;
        if (keep != null) {
            long seconds = Long.parseLong(keep);
            if (seconds <= 0) throw new IllegalArgumentException("Invalid keepLastSeconds");
            Instant end = latest(input);
            if (end != null) cutoff = end.minusSeconds(seconds);
        }
        var periods = new HashMap<String, Long>();
        var eventNames = new HashMap<Long, String>();
        var methods = new HashMap<String, Integer>();
        var stacks = new HashMap<String, Integer>();
        var luaFunctions = new HashMap<String, Integer>();
        var luaStacks = new HashMap<String, Integer>();
        var threads = new HashMap<Long, String>();
        var body = new StringBuilder(1 << 20);
        var tables = new StringBuilder(1 << 16);
        long samples = 0, frames = 0, luaSamples = 0, last = 0;
        long gameThread = -1;
        Instant origin = null;
        try (RecordingFile reader = new RecordingFile(input);
             var writer = new BufferedWriter(new OutputStreamWriter(new GZIPOutputStream(Files.newOutputStream(output)), StandardCharsets.UTF_8))) {
            writer.write("PZPROF\t1\n");
            for (var entry : information.entrySet()) writer.write("I\t" + entry.getKey() + "\t" + clean(entry.getValue()) + "\n");
            for (var eventType : reader.readEventTypes()) eventNames.put(eventType.getId(), eventType.getName());
            while (reader.hasMoreEvents()) {
                RecordedEvent event = reader.readEvent();
                String type = event.getEventType().getName();
                if (cutoff != null && event.getStartTime().isBefore(cutoff)) {
                    // The sampling periods are set once, at the start of each chunk: still needed for what is kept.
                    if (type.equals("jdk.ActiveSetting")) period(event, eventNames, periods);
                    continue;
                }
                if (origin == null) origin = event.getStartTime();
                // Events are not stored in time order, so a time may be negative; the reader sorts and rebases.
                long time = micros(origin, event.getStartTime());
                last = Math.max(last, time + Math.max(0, event.getDuration().toNanos() / 1000));
                switch (type) {
                    case "jdk.ExecutionSample", "jdk.NativeMethodSample" -> {
                        RecordedThread thread = event.getThread("sampledThread");
                        RecordedStackTrace trace = event.getStackTrace();
                        if (thread == null || trace == null) break;
                        long id = thread.getJavaThreadId();
                        threads.putIfAbsent(id, name(thread));
                        int stack = stack(trace, methods, stacks, tables);
                        body.append("S\t").append(time).append('\t').append(id).append('\t').append(stack).append('\t')
                            .append(type.equals("jdk.NativeMethodSample") ? 'N' : 'J').append('\n');
                        samples++;
                    }
                    case "pztools.Frame" -> {
                        RecordedThread thread = event.getThread();
                        if (thread != null) { gameThread = thread.getJavaThreadId(); threads.putIfAbsent(gameThread, name(thread)); }
                        body.append("F\t").append(time).append('\t').append(event.getDuration().toNanos() / 1000).append('\n');
                        frames++;
                    }
                    case "pztools.LuaSample" -> {
                        String text = event.getString("stack");
                        if (text == null || text.isEmpty()) break;
                        Integer known = luaStacks.get(text);
                        if (known == null) {
                            known = luaStacks.size();
                            luaStacks.put(text, known);
                            var line = new StringBuilder("LK\t").append(known).append('\t');
                            boolean first = true;
                            for (String frame : text.split("\n")) {
                                // name|file|line, written by the sampler.
                                int lastBar = frame.lastIndexOf('|'), firstBar = frame.indexOf('|');
                                if (firstBar <= 0 || lastBar <= firstBar) continue;
                                String function = frame.substring(0, lastBar);
                                Integer functionId = luaFunctions.get(function);
                                if (functionId == null) {
                                    functionId = luaFunctions.size();
                                    luaFunctions.put(function, functionId);
                                    tables.append("LM\t").append(functionId).append('\t').append(clean(luaName(frame.substring(0, firstBar))))
                                        .append('\t').append(clean(luaPath(frame.substring(firstBar + 1, lastBar)))).append('\n');
                                }
                                if (!first) line.append(' ');
                                first = false;
                                line.append(functionId).append(':').append(number(frame.substring(lastBar + 1)));
                            }
                            tables.append(line).append('\n');
                        }
                        body.append("L\t").append(time).append('\t').append(known).append('\n');
                        long allocated = allocated(event);
                        if (allocated >= 0) body.append("LA\t").append(time).append('\t').append(allocated).append('\n');
                        luaSamples++;
                    }
                    case "pztools.LuaSampler" -> {
                        body.append("LH\t").append(time).append('\t').append(event.getLong("taken")).append('\t')
                            .append(event.getLong("inLua")).append('\t').append(event.getLong("periodMicros")).append('\n');
                        long allocated = allocated(event);
                        if (allocated >= 0) body.append("GA\t").append(time).append('\t').append(allocated).append('\n');
                    }
                    case "jdk.GCHeapMemoryUsage" -> body.append("H\t").append(time).append('\t').append(event.getLong("used"))
                        .append('\t').append(event.getLong("committed")).append('\t').append(event.getLong("max")).append('\n');
                    case "jdk.GarbageCollection" -> body.append("G\t").append(time).append('\t')
                        .append(event.getDuration("sumOfPauses").toNanos() / 1000).append('\t')
                        .append(clean(event.getString("name"))).append('\t').append(clean(event.getString("cause"))).append('\n');
                    case "jdk.GCPhasePause", "jdk.ZAllocationStall", "jdk.JavaMonitorEnter", "jdk.ThreadPark", "jdk.FileRead", "jdk.FileWrite",
                         "jdk.ExecuteVMOperation" -> {
                        RecordedThread thread = event.getThread();
                        long id = thread == null ? -1 : thread.getJavaThreadId();
                        if (thread != null) threads.putIfAbsent(id, name(thread));
                        body.append("P\t").append(time).append('\t').append(event.getDuration().toNanos() / 1000).append('\t')
                            .append(type.substring(4)).append('\t').append(id).append('\t').append(clean(detail(event, type))).append('\n');
                    }
                    // How often each kind of sample was asked for; the reader needs it to turn counts into time.
                    case "jdk.ActiveSetting" -> period(event, eventNames, periods);
                    default -> { }
                }
                // Keep memory bounded on long recordings: tables first, so every reference is already defined.
                if (body.length() > (1 << 20)) { writer.write(tables.toString()); writer.write(body.toString()); tables.setLength(0); body.setLength(0); }
            }
            writer.write(tables.toString());
            writer.write(body.toString());
            for (var thread : threads.entrySet())
                writer.write("T\t" + thread.getKey() + "\t" + clean(thread.getValue()) + "\n");
            writer.write("I\tgameThread\t" + gameThread + "\n");
            writer.write("I\tjavaPeriodMicros\t" + periods.getOrDefault("jdk.ExecutionSample", 0L) + "\n");
            writer.write("I\tnativePeriodMicros\t" + periods.getOrDefault("jdk.NativeMethodSample", 0L) + "\n");
            writer.write("I\tdurationMicros\t" + last + "\n");
            writer.write("I\tstartEpochMillis\t" + (origin == null ? 0 : origin.toEpochMilli()) + "\n");
            writer.write("I\tsamples\t" + samples + "\n");
            writer.write("I\tframes\t" + frames + "\n");
            writer.write("I\tluaSamples\t" + luaSamples + "\n");
        }
        return new long[] { samples, frames, luaSamples, last };
    }

    private static void period(RecordedEvent event, Map<Long, String> eventNames, Map<String, Long> periods) {
        try {
            if (!"period".equals(event.getString("name"))) return;
            String owner = eventNames.get(event.getLong("id"));
            long period = periodMicros(event.getString("value"));
            if (owner != null && period > 0) periods.put(owner, period);
        } catch (RuntimeException differentShape) { }
    }

    /** When the recording's last event ends; null for one without events. */
    private static Instant latest(Path input) throws IOException {
        Instant last = null;
        try (RecordingFile reader = new RecordingFile(input)) {
            while (reader.hasMoreEvents()) {
                Instant end = reader.readEvent().getEndTime();
                if (last == null || end.isAfter(last)) last = end;
            }
        }
        return last;
    }

    private static int stack(RecordedStackTrace trace, Map<String, Integer> methods, Map<String, Integer> stacks, StringBuilder tables) {
        var key = new StringBuilder();
        int depth = 0;
        for (RecordedFrame frame : trace.getFrames()) {
            if (depth++ >= MAXIMUM_DEPTH) break;
            RecordedMethod method = frame.getMethod();
            String label = method == null || method.getType() == null ? "?" : method.getType().getName() + "." + method.getName();
            Integer id = methods.get(label);
            if (id == null) {
                id = methods.size();
                methods.put(label, id);
                tables.append("M\t").append(id).append('\t').append(clean(label)).append('\n');
            }
            if (key.length() != 0) key.append(' ');
            key.append(id);
        }
        String text = key.toString();
        Integer known = stacks.get(text);
        if (known == null) {
            known = stacks.size();
            stacks.put(text, known);
            tables.append("K\t").append(known).append('\t').append(text).append('\n');
        }
        return known;
    }

    // A recording made before allocations were read has no such field.
    private static long allocated(RecordedEvent event) {
        return event.hasField("allocated") ? event.getLong("allocated") : -1;
    }

    private static String detail(RecordedEvent event, String type) {
        try {
            return switch (type) {
                case "jdk.GCPhasePause" -> event.getString("name");
                case "jdk.JavaMonitorEnter" -> event.getClass("monitorClass") == null ? "" : event.getClass("monitorClass").getName();
                case "jdk.ThreadPark" -> event.getClass("parkedClass") == null ? "" : event.getClass("parkedClass").getName();
                case "jdk.FileRead", "jdk.FileWrite" -> fileName(event.getString("path"));
                case "jdk.ExecuteVMOperation" -> event.getString("operation");
                default -> "";
            };
        } catch (RuntimeException differentShape) { return ""; }
    }
    // A file name is enough to recognise the work; full paths would put the user's folders into a file meant to be shared.
    private static String fileName(String path) {
        if (path == null) return "";
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash < 0 ? path : path.substring(slash + 1);
    }
    /**
     * The part of a Lua file path that says which mod and which file, without the folders above it:
     * a recording is meant to be handed to someone else, and those folders carry the user name.
     */
    static String luaPath(String path) {
        String value = path.replace('\\', '/');
        String lower = value.toLowerCase(Locale.ROOT);
        int mods = lower.lastIndexOf("/mods/");
        if (mods >= 0) {
            // Steam Workshop: .../workshop/content/108600/<item>/mods/<mod>/...
            int item = lower.lastIndexOf('/', mods - 1);
            String before = item >= 0 ? value.substring(item + 1, mods) : "";
            boolean workshop = !before.isEmpty() && before.chars().allMatch(Character::isDigit) && lower.contains("/108600/");
            return (workshop ? "workshop/" + before + "/" : "") + value.substring(mods + 1);
        }
        int media = lower.lastIndexOf("/media/");
        if (media >= 0) return value.substring(media + 1);
        if (lower.startsWith("media/") || lower.startsWith("mods/")) return value;
        int slash = value.lastIndexOf('/');
        return slash < 0 ? value : value.substring(slash + 1);
    }
    /**
     * A Lua function's name as the recording keeps it. A file's top-level code is named after the file's full path,
     * folders above the game or the mod included; its file name says the same without them. A function name never
     * holds a slash, so only such a name changes.
     */
    static String luaName(String name) {
        int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
        return slash < 0 ? name : name.substring(slash + 1);
    }
    private static String name(RecordedThread thread) {
        String name = thread.getJavaName();
        return name != null ? name : thread.getOSName() != null ? thread.getOSName() : "thread-" + thread.getJavaThreadId();
    }
    private static long micros(Instant origin, Instant value) {
        return (value.getEpochSecond() - origin.getEpochSecond()) * 1_000_000L + (value.getNano() - origin.getNano()) / 1000L;
    }
    private static long periodMicros(String text) {
        if (text == null) return 0;
        String[] parts = text.trim().split("\\s+");
        try {
            double value = Double.parseDouble(parts[0]);
            String unit = parts.length > 1 ? parts[1] : "ms";
            double factor = switch (unit) { case "ns" -> 0.001; case "us" -> 1; case "ms" -> 1000; case "s" -> 1_000_000; default -> 0; };
            return Math.round(value * factor);
        } catch (NumberFormatException notAPeriod) { return 0; }
    }
    private static int number(String text) {
        try { return Integer.parseInt(text.trim()); } catch (NumberFormatException invalid) { return 0; }
    }
    private static String clean(String value) {
        if (value == null || value.isEmpty()) return "?";
        return value.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
    }
}
