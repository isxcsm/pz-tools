package pztools.bridge.runtime;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.IdentityHashMap;
import java.util.concurrent.locks.LockSupport;
import jdk.jfr.*;

/**
 * The recording asked for and the rolling one, each started and stopped on request, alone or together. Nothing is
 * sampled, hooked or kept while neither runs.
 *
 * <p>The JVM's own flight recorder does the measuring: periodic stack samples of running threads,
 * garbage-collection pauses, and the events below. It depends on Java, not on the game's code,
 * so a game update cannot break it. The two game-specific parts are optional and each stands
 * alone: frame boundaries (the existing game-loop hook) and Lua frames (read from the game's
 * Lua interpreter). Missing either, the recording still has everything else.
 */
final class ProfileRecorder {
    @Name("pztools.Frame") @Label("Game frame") @Category("PZ Tools") @StackTrace(false)
    static final class FrameEvent extends Event { }

    /**
     * Innermost first, as {@code name|file|line} joined by tabs-free separators; see {@link LuaSampler}.
     * {@code allocated}: bytes the game thread allocated since the sampler's previous look, -1 when unknown.
     */
    @Name("pztools.LuaSample") @Label("Lua sample") @Category("PZ Tools") @StackTrace(false)
    static final class LuaSampleEvent extends Event {
        @Label("Stack") String stack;
        @Label("Allocated since the previous sample") @DataAmount long allocated;
    }

    @Name("pztools.LuaSampler") @Label("Lua sampler") @Category("PZ Tools") @StackTrace(false)
    static final class LuaSamplerEvent extends Event {
        @Label("Samples taken") long taken;
        @Label("Samples in Lua") long inLua;
        @Label("Period in microseconds") long periodMicros;
        /** Everything the game thread allocated since the previous report, in Lua or not; -1 when unknown. */
        @Label("Game thread allocated") @DataAmount long allocated;
    }

    static final int MAXIMUM_SECONDS = 1800, MAXIMUM_ROLLING_SECONDS = 600, DEFAULT_ROLLING_MEGABYTES = 256;

    /** One recording with what its status reports: its mode, when it began, and the frame count it began at. */
    private static final class Slot {
        final Recording recording;
        final boolean detailed;
        final long startedNanos = System.nanoTime(), startFrames;
        Slot(Recording recording, boolean detailed, long startFrames) {
            this.recording = recording; this.detailed = detailed; this.startFrames = startFrames;
        }
        boolean running() { return recording.getState() == RecordingState.RUNNING; }
    }

    // The recording asked for, and the rolling one, which keeps only its last stretch and has no end of its own (see
    // startRolling). Both may run at once: the flight recorder takes each event once and every running recording
    // that enabled it gets it. The frame marks, the Lua sampler and the timer resolution are shared, and run while
    // either recording does; the sampler at the shorter of their periods. The converter takes each recording back to
    // its own mode's density.
    private static volatile Slot asked, rolling;
    private static LuaSampler lua;
    private static Thread luaThread;
    private static String luaState = "not-started";
    private static volatile boolean active;
    // Frames marked since the recorder first ran; each recording counts from where it began.
    private static volatile long frames;
    // Game thread only while active.
    private static FrameEvent open;
    // The thread that runs the game loop, and with it the game's Lua: whose allocations the Lua sampler reads.
    private static volatile Thread gameThread;
    // What the game loop calls through ProfileFrames while a recording runs; one instance, so it detaches only itself.
    private static final Runnable FRAME_MARK = ProfileRecorder::frame;

    private ProfileRecorder() { }

    static boolean active() { return active; }
    /**
     * Any thread: whether the flight recorder is still taking events for either recording; the one asked for ends by
     * itself at its maximum duration.
     */
    static boolean running() { return active && (live(asked) || live(rolling)); }

    private static boolean live(Slot slot) { return slot != null && slot.running(); }

    /** Game thread, once per game-loop iteration. One branch when nothing is being recorded. */
    static void frame() {
        if (!active) return;
        FrameEvent previous = open;
        if (previous != null) { previous.end(); previous.commit(); }
        else if (gameThread == null) gameThread = Thread.currentThread();
        FrameEvent next = new FrameEvent();
        next.begin();
        open = next;
        frames++;
    }

    /** Starts the recording asked for; a rolling one goes on beside it. */
    static synchronized String start(Path destination, boolean detailedMode, int maximumSeconds, ClassLoader gameLoader) throws Exception {
        if (live(asked)) throw new IllegalStateException("already-recording");
        // One that ended by itself at its limit and was never stopped.
        close(asked);
        checkDestination(destination);
        if (maximumSeconds < 5 || maximumSeconds > MAXIMUM_SECONDS) throw new IllegalArgumentException("Invalid maximum duration");
        Recording next = configured(detailedMode);
        try {
            next.setDumpOnExit(true);
            next.setMaxSize(512L * 1024 * 1024);
            next.setDuration(Duration.ofSeconds(maximumSeconds));
            next.setDestination(destination);
        } catch (Throwable failure) { next.close(); throw failure; }
        return status(begin(next, detailedMode, gameLoader, false));
    }

    /**
     * Keeps recording, holding only about the last {@code keepSeconds}, until stopped: for the stutter that already
     * happened, saved with {@link #save} after it. Older data is dropped a whole chunk at a time, so somewhat more is
     * held; the converter cuts a save to the window. A recording asked for runs beside it; a rolling one already
     * running is replaced, as when its mode or window changes.
     */
    static synchronized String startRolling(boolean detailedMode, int keepSeconds, ClassLoader gameLoader) throws Exception {
        return startRolling(detailedMode, keepSeconds, DEFAULT_ROLLING_MEGABYTES, gameLoader);
    }

    static synchronized String startRolling(boolean detailedMode, int keepSeconds, int maxMegabytes, ClassLoader gameLoader) throws Exception {
        if (keepSeconds < 10 || keepSeconds > MAXIMUM_ROLLING_SECONDS) throw new IllegalArgumentException("Invalid rolling duration");
        if (maxMegabytes < 64 || maxMegabytes > 2048) throw new IllegalArgumentException("Invalid rolling size");
        Slot previous = rolling;
        rolling = null;
        close(previous);
        Recording next = configured(detailedMode);
        try {
            next.setMaxAge(Duration.ofSeconds(keepSeconds));
            next.setMaxSize(maxMegabytes * 1024L * 1024);
        } catch (Throwable failure) { next.close(); release(); throw failure; }
        return status(begin(next, detailedMode, gameLoader, true));
    }

    /** Writes what the rolling recording holds now; it goes on recording. */
    static synchronized String save(Path destination) throws Exception {
        Slot slot = rolling;
        if (!active || !live(slot)) throw new IllegalStateException("not-rolling");
        checkDestination(destination);
        slot.recording.dump(destination);
        return status(slot);
    }

    /** Ends the rolling recording, and only that: a recording someone asked for is left alone. */
    static synchronized String stopRolling() {
        Slot slot = rolling;
        if (slot == null) return status();
        String result = status(slot);
        rolling = null;
        close(slot);
        return result;
    }

    private static void checkDestination(Path destination) {
        if (!destination.isAbsolute() || !destination.getFileName().toString().endsWith(".jfr")
                || !Files.isDirectory(destination.getParent()))
            throw new IllegalArgumentException("An absolute .jfr path in an existing directory is required");
    }

    /** The events both kinds of recording take, in the chosen mode. */
    private static Recording configured(boolean detailedMode) {
        Recording next = new Recording();
        try {
            next.setName("PZ Tools");
            // Running Java code, and threads inside native calls (rendering, physics, sound, file access).
            next.enable("jdk.ExecutionSample").with("period", detailedMode ? "1 ms" : "10 ms");
            next.enable("jdk.NativeMethodSample").with("period", detailedMode ? "10 ms" : "20 ms");
            // Records the periods actually in force, which the converter needs to turn sample counts into time.
            next.enable("jdk.ActiveSetting");
            next.enable("jdk.GarbageCollection");
            next.enable("jdk.GCPhasePause");
            next.enable("jdk.ZAllocationStall");
            // How full the Java heap is, four times a second: it fills between collections and drops at each.
            next.enable("jdk.GCHeapMemoryUsage").withPeriod(Duration.ofMillis(250));
            if (detailedMode) {
                // Where a thread was not running at all: waiting for a lock, parked, blocked on a file, stopped by the JVM.
                next.enable("jdk.JavaMonitorEnter").withThreshold(Duration.ofMillis(1));
                next.enable("jdk.ThreadPark").withThreshold(Duration.ofMillis(2));
                next.enable("jdk.FileRead").withThreshold(Duration.ofMillis(1));
                next.enable("jdk.FileWrite").withThreshold(Duration.ofMillis(1));
                next.enable("jdk.ExecuteVMOperation").withThreshold(Duration.ofMillis(1));
            }
            next.enable(FrameEvent.class);
            next.enable(LuaSampleEvent.class);
            next.enable(LuaSamplerEvent.class);
            next.setToDisk(true);
        } catch (Throwable failure) { next.close(); throw failure; }
        return next;
    }

    /** Starts a recording and, with the first one, what both share; the sampler follows the shorter period. */
    private static Slot begin(Recording next, boolean detailedMode, ClassLoader gameLoader, boolean keepsRolling) {
        boolean first = !live(asked) && !live(rolling);
        try {
            TimerResolution.raise();
            next.start();
        } catch (Throwable failure) { next.close(); release(); throw failure; }
        if (first) { open = null; gameThread = null; }
        Slot slot = new Slot(next, detailedMode, frames);
        if (keepsRolling) rolling = slot; else asked = slot;
        long period = samplingPeriod();
        if (lua != null) lua.periodNanos = period;
        else {
            LuaSampler sampler = null;
            try { sampler = new LuaSampler(gameLoader, period); luaState = "sampling"; }
            catch (ReflectiveOperationException | LinkageError unavailable) { luaState = "unavailable:" + unavailable.getClass().getSimpleName(); }
            lua = sampler;
            if (sampler != null) {
                luaThread = new Thread(sampler, "PzTools-lua-sampler");
                luaThread.setDaemon(true);
                luaThread.start();
            }
        }
        active = true;
        ProfileFrames.attach(FRAME_MARK);
        return slot;
    }

    // The Lua sampler's period: the shorter of the running recordings' modes.
    private static long samplingPeriod() {
        return live(asked) && asked.detailed || live(rolling) && rolling.detailed ? 1_000_000L : 10_000_000L;
    }

    /**
     * After a recording has stopped: with neither running, stop what they shared (frame marks, Lua sampler, timer
     * resolution); with one still running, the sampler goes back to its period.
     */
    private static void release() {
        if (live(asked) || live(rolling)) {
            if (lua != null) lua.periodNanos = samplingPeriod();
            return;
        }
        active = false; open = null;
        ProfileFrames.detach(FRAME_MARK);
        stopLua();
        TimerResolution.restore();
    }

    /** Stops and closes a recording that is no longer wanted, quietly. */
    private static void close(Slot slot) {
        if (slot == null) return;
        if (asked == slot) asked = null;
        if (rolling == slot) rolling = null;
        try { slot.recording.close(); } catch (Throwable ignored) { }
        release();
    }

    /** Ends the recording asked for, which writes its file; a rolling one goes on. */
    static synchronized String stop() throws Exception {
        Slot slot = asked;
        if (slot == null) throw new IllegalStateException("not-recording");
        String result = status(slot);
        asked = null;
        try { if (slot.running()) slot.recording.stop(); }
        finally { slot.recording.close(); release(); }
        return result;
    }

    /**
     * The flight recorder ended the recording asked for by itself at its maximum duration, and nobody has asked for
     * it to stop (the recording program may have ended). Give back what it held of the shared parts: all of them
     * unless the rolling recording still runs. The recording itself stays, so a later stop request still reports it
     * as finished.
     */
    static synchronized void wrapUpIfEnded() {
        if (active && (asked != null || rolling != null)) release();
    }

    /** {@code state;elapsedMillis;frames;mode;lua} for the recording asked for if there is one, else the rolling one. */
    static synchronized String status() { return status(asked != null ? asked : rolling); }

    /** Fixed fields, no free text. */
    private static String status(Slot slot) {
        if (slot == null) return "idle;0;0;general;" + luaState;
        // The recorder ends a recording by itself at its maximum duration; that is "finished", not lost.
        String state = !slot.running() ? "finished" : slot == rolling ? "rolling" : "recording";
        long elapsed = (System.nanoTime() - slot.startedNanos) / 1_000_000L;
        return state + ";" + elapsed + ";" + (frames - slot.startFrames) + ";" + (slot.detailed ? "detailed" : "general") + ";" + luaState;
    }

    /** Payload replacement or shutdown: leave nothing running that belongs to a retiring class loader. */
    static synchronized void closeQuietly() {
        Slot first = asked, second = rolling;
        asked = null; rolling = null;
        for (Slot slot : new Slot[] { first, second })
            if (slot != null) try { slot.recording.close(); } catch (Throwable ignored) { }
        release();
    }

    private static void stopLua() {
        LuaSampler sampler = lua; Thread thread = luaThread;
        lua = null; luaThread = null;
        if (sampler != null) sampler.stopped = true;
        if (thread != null) {
            LockSupport.unpark(thread);
            try { thread.join(500); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }
    }

    /**
     * Reads which Lua function the game is in, from another thread and without stopping the game.
     * The interpreter's call stack is plain Java objects; reading them while they change can give
     * a frame that is one call out of date, never a crash, and each sample is only one vote among
     * many. Mods are Lua, so this is what attributes time to a mod and a function.
     */
    static final class LuaSampler implements Runnable {
        private static final int MAXIMUM_DEPTH = 24, MAXIMUM_CACHE = 8192, MAXIMUM_STACK_TEXT = 4096;
        // Method handles, not reflection: access is checked once, here, instead of on every read, and nothing is
        // boxed. Types are erased to Object (or int) so the reads are exact calls; checked above them by type.
        private final MethodHandle[] threads;
        private final MethodHandle currentCoroutine, closure, pc, prototype, name, file, filename, lines, top, stack;
        // Shared by both recordings: set again when one starts or stops, read before each wait.
        volatile long periodNanos;
        private final IdentityHashMap<Object, String> labels = new IdentityHashMap<>();
        private final PreciseWait wait = new PreciseWait();
        volatile boolean stopped;

        LuaSampler(ClassLoader game, long periodNanos) throws ReflectiveOperationException {
            this.periodNanos = periodNanos;
            Class<?> kahlua = Class.forName("se.krka.kahlua.vm.KahluaThread", false, game);
            Class<?> coroutine = Class.forName("se.krka.kahlua.vm.Coroutine", false, game);
            Class<?> frame = Class.forName("se.krka.kahlua.vm.LuaCallFrame", false, game);
            Class<?> closureType = Class.forName("se.krka.kahlua.vm.LuaClosure", false, game);
            Class<?> prototypeType = Class.forName("se.krka.kahlua.vm.Prototype", false, game);
            Field main = Class.forName("zombie.Lua.LuaManager", false, game).getField("thread");
            if (main.getType() != kahlua) throw new NoSuchFieldException("LuaManager.thread");
            Field ui = null;
            // The interface runs on its own interpreter thread object; without it only game logic Lua is seen.
            try { ui = Class.forName("zombie.ui.UIManager", false, game).getField("defaultthread"); if (ui.getType() != kahlua) ui = null; }
            catch (ReflectiveOperationException absent) { ui = null; }
            threads = ui == null ? new MethodHandle[] { read(main) } : new MethodHandle[] { read(main), read(ui) };
            currentCoroutine = read(typed(kahlua.getField("currentCoroutine"), coroutine));
            Method callTop = coroutine.getMethod("getCallframeTop"), callStack = coroutine.getMethod("getCallframeStack");
            if (callTop.getReturnType() != int.class || callStack.getReturnType() != frame.arrayType()) throw new NoSuchMethodException("Coroutine call frames");
            top = call(callTop);
            stack = call(callStack);
            closure = read(typed(frame.getField("closure"), closureType));
            pc = read(typed(frame.getField("pc"), int.class));
            prototype = read(typed(closureType.getField("prototype"), prototypeType));
            name = read(typed(prototypeType.getField("name"), String.class));
            file = read(typed(prototypeType.getField("file"), String.class));
            filename = read(typed(prototypeType.getField("filename"), String.class));
            lines = read(typed(prototypeType.getField("lines"), int[].class));
        }
        private static Field typed(Field field, Class<?> type) throws NoSuchFieldException {
            if (field.getType() != type) throw new NoSuchFieldException(field.getName());
            return field;
        }
        /** A field's getter as ()Object for a static field or (Object)Object, primitives kept. */
        private static MethodHandle read(Field field) throws IllegalAccessException {
            Class<?> value = field.getType().isPrimitive() ? field.getType() : Object.class;
            MethodHandle getter = MethodHandles.publicLookup().unreflectGetter(field);
            return getter.asType(java.lang.reflect.Modifier.isStatic(field.getModifiers())
                ? MethodType.methodType(value) : MethodType.methodType(value, Object.class));
        }
        /** A no-argument instance method as (Object)Object, primitives kept. */
        private static MethodHandle call(Method method) throws IllegalAccessException {
            Class<?> value = method.getReturnType().isPrimitive() ? method.getReturnType() : Object.class;
            return MethodHandles.publicLookup().unreflect(method).asType(MethodType.methodType(value, Object.class));
        }

        @Override public void run() {
            long taken = 0, inLua = 0, lastReport = System.nanoTime();
            // What the game thread allocated, by its JVM counter: the bytes since the previous look go to the Lua
            // function found running now, the same vote a sample casts for time.
            ThreadAllocation allocation;
            try { allocation = ThreadAllocation.open(); } catch (LinkageError absent) { allocation = null; }
            Thread counted = null;
            long lastBytes = -1, reportBytes = -1;
            var text = new StringBuilder(512);
            // The game often stays in one place for many samples in a row: the same text is then the same string,
            // so it makes no garbage in the game's heap and the recorder finds it already in its string pool.
            String previousStack = "";
            try {
                while (!stopped) {
                    wait.pause(periodNanos);
                    if (stopped) break;
                    taken++;
                    long allocated = -1;
                    Thread game = gameThread;
                    if (allocation != null && game != null) {
                        long bytes = allocation.of(game);
                        if (bytes >= 0 && counted == game && lastBytes >= 0) allocated = Math.max(0, bytes - lastBytes);
                        counted = game; lastBytes = bytes;
                        if (allocated >= 0) reportBytes = Math.max(0, reportBytes) + allocated;
                    }
                    text.setLength(0);
                    try { read(text); } catch (Throwable racing) { text.setLength(0); }
                    if (text.length() != 0) {
                        inLua++;
                        if (!previousStack.contentEquals(text)) previousStack = text.toString();
                        LuaSampleEvent event = new LuaSampleEvent();
                        event.stack = previousStack;
                        event.allocated = allocated;
                        event.commit();
                    }
                    long now = System.nanoTime();
                    if (now - lastReport >= 1_000_000_000L) {
                        report(taken, inLua, reportBytes); taken = inLua = 0; reportBytes = -1; lastReport = now;
                        // The recording ended by itself: stop reading the game for nobody. Checked once
                        // a second; counting samples for this missed it in Standard mode, where the
                        // count is reset before it gets that far.
                        if (!ProfileRecorder.running()) break;
                    }
                }
                report(taken, inLua, reportBytes);
            } finally { wait.close(); if (allocation != null) allocation.close(); }
        }
        private void report(long taken, long inLua, long allocated) {
            LuaSamplerEvent event = new LuaSamplerEvent();
            event.taken = taken; event.inLua = inLua; event.periodMicros = periodNanos / 1000; event.allocated = allocated;
            event.commit();
        }

        private void read(StringBuilder out) throws Throwable {
            for (MethodHandle thread : threads) {
                Object interpreter = (Object)thread.invokeExact();
                if (interpreter == null) continue;
                Object coroutine = (Object)currentCoroutine.invokeExact(interpreter);
                if (coroutine == null) continue;
                int depth = (int)top.invokeExact(coroutine);
                Object[] frames = (Object[])(Object)stack.invokeExact(coroutine);
                if (depth <= 0 || frames == null) continue;
                int written = 0;
                for (int index = Math.min(depth, frames.length) - 1; index >= 0 && written < MAXIMUM_DEPTH; index--) {
                    Object callFrame = frames[index];
                    if (callFrame == null) continue;
                    Object function = (Object)closure.invokeExact(callFrame);
                    if (function == null) continue; // A Java function called from Lua; the Java samples cover it.
                    Object code = (Object)prototype.invokeExact(function);
                    if (code == null) continue;
                    String label = labels.get(code);
                    if (label == null) {
                        if (labels.size() >= MAXIMUM_CACHE) labels.clear();
                        label = clean((String)(Object)name.invokeExact(code)) + "|"
                            + clean(firstNonEmpty((String)(Object)filename.invokeExact(code), (String)(Object)file.invokeExact(code)));
                        labels.put(code, label);
                    }
                    int line = 0, counter = (int)pc.invokeExact(callFrame) - 1;
                    int[] lineTable = (int[])(Object)lines.invokeExact(code);
                    if (lineTable != null && counter >= 0 && counter < lineTable.length) line = lineTable[counter];
                    if (out.length() + label.length() + 16 > MAXIMUM_STACK_TEXT) break;
                    if (written++ != 0) out.append('\n');
                    out.append(label).append('|').append(line);
                }
                if (written != 0) return; // One interpreter runs at a time on the game thread.
            }
        }
        private static String firstNonEmpty(String first, String second) { return first != null && !first.isEmpty() ? first : second; }
        private static String clean(String value) {
            if (value == null || value.isEmpty()) return "?";
            if (value.length() > 240) value = value.substring(value.length() - 240);
            return value.replace('|', '/').replace('\n', ' ').replace('\r', ' ').replace('\t', ' ');
        }
    }

    /**
     * How many bytes a thread has allocated so far, from the JVM's own per-thread counter: a read is a
     * short lookup, and nothing is hooked or instrumented. Absent where the runtime
     * lacks the management module or the counter, and then the recording simply has no allocations.
     */
    static final class ThreadAllocation {
        private final com.sun.management.ThreadMXBean threads;
        private final boolean enabledHere;
        private ThreadAllocation(com.sun.management.ThreadMXBean threads, boolean enabledHere) {
            this.threads = threads; this.enabledHere = enabledHere;
        }

        /** Null when unavailable. A runtime without the module fails to link this class; the caller catches that. */
        static ThreadAllocation open() {
            try {
                if (!(java.lang.management.ManagementFactory.getThreadMXBean() instanceof com.sun.management.ThreadMXBean threads)
                        || !threads.isThreadAllocatedMemorySupported()) return null;
                // On by default. Turned on only if someone turned it off, and turned off again by {@link #close()}:
                // the setting is the whole JVM's, and another agent may have its reasons.
                boolean enable = !threads.isThreadAllocatedMemoryEnabled();
                if (enable) threads.setThreadAllocatedMemoryEnabled(true);
                return new ThreadAllocation(threads, enable);
            } catch (RuntimeException | LinkageError unavailable) { return null; }
        }

        /** Leaves the JVM's setting as it was found. */
        void close() {
            if (!enabledHere) return;
            try { threads.setThreadAllocatedMemoryEnabled(false); } catch (RuntimeException ignored) { }
        }

        /** -1 when the thread has ended or the counter is off. */
        long of(Thread thread) {
            try { return threads.getThreadAllocatedBytes(thread.threadId()); } catch (RuntimeException unavailable) { return -1; }
        }
    }

    /**
     * The flight recorder's sampler sleeps between samples, and on Windows a sleep is rounded up to
     * the system timer tick (15.6 ms by default): a 10 ms or 1 ms sampling period would silently
     * become 15.6 ms. Asking for a 1 ms tick while a recording runs is what games and media players
     * routinely do; it is undone when the recording ends and applies to this process only.
     */
    static final class TimerResolution {
        private static MethodHandle begin, end;
        private static boolean raised;
        static synchronized void raise() {
            if (raised) return;
            try {
                if (!System.getProperty("os.name", "").startsWith("Windows")) return;
                if (begin == null) {
                    Linker linker = Linker.nativeLinker();
                    SymbolLookup winmm = SymbolLookup.libraryLookup("winmm", Arena.global());
                    FunctionDescriptor shape = FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT);
                    begin = linker.downcallHandle(winmm.find("timeBeginPeriod").orElseThrow(), shape);
                    end = linker.downcallHandle(winmm.find("timeEndPeriod").orElseThrow(), shape);
                }
                raised = (int)begin.invokeExact(1) == 0;
            } catch (Throwable unavailable) { raised = false; }
        }
        static synchronized void restore() {
            if (!raised) return;
            raised = false;
            try { int ignored = (int)end.invokeExact(1); } catch (Throwable unavailable) { }
        }
    }

    /**
     * A short wait that is actually short. The JVM's own sleeps fall back to the 15 ms system tick
     * on Windows, which would turn a 1 ms sampler into a 15 ms one. A private high-resolution
     * timer avoids that without raising the system-wide timer rate; elsewhere the portable wait is used.
     */
    static final class PreciseWait {
        private MethodHandle setTimer, waitFor, closeHandle;
        private MemorySegment timer, due;
        PreciseWait() {
            try {
                if (!System.getProperty("os.name", "").startsWith("Windows")) return;
                Linker linker = Linker.nativeLinker();
                SymbolLookup kernel = SymbolLookup.libraryLookup("kernel32", Arena.global());
                MethodHandle create = linker.downcallHandle(kernel.find("CreateWaitableTimerExW").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT));
                setTimer = linker.downcallHandle(kernel.find("SetWaitableTimer").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT,
                        ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
                waitFor = linker.downcallHandle(kernel.find("WaitForSingleObject").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
                closeHandle = linker.downcallHandle(kernel.find("CloseHandle").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
                due = Arena.ofAuto().allocate(ValueLayout.JAVA_LONG);
                MemorySegment created = (MemorySegment)create.invokeExact(MemorySegment.NULL, MemorySegment.NULL, 0x2, 0x1F0003);
                timer = created.address() == 0 ? null : created;
            } catch (Throwable unavailable) { timer = null; }
        }
        // The period the timer repeats at once armed, so each pause is one wait instead of arming and waiting; 0 when
        // not armed, -1 when the system refused a repeating timer and each pause arms it once.
        private long periodicNanos;

        void pause(long nanos) {
            MemorySegment current = timer;
            if (current != null) {
                try {
                    if (periodicNanos != nanos && periodicNanos >= 0) {
                        // A repeating timer counts its ticks in milliseconds, which both sampling periods are.
                        due.set(ValueLayout.JAVA_LONG, 0, -Math.max(1, nanos / 100));
                        int period = (int)Math.max(1, nanos / 1_000_000);
                        int armed = (int)setTimer.invokeExact(current, due, period, MemorySegment.NULL, MemorySegment.NULL, 0);
                        periodicNanos = armed != 0 && nanos % 1_000_000 == 0 ? nanos : -1;
                    }
                    if (periodicNanos < 0) {
                        due.set(ValueLayout.JAVA_LONG, 0, -Math.max(1, nanos / 100));
                        int armed = (int)setTimer.invokeExact(current, due, 0, MemorySegment.NULL, MemorySegment.NULL, 0);
                        if (armed == 0) throw new IllegalStateException("timer");
                    }
                    // A tick missed while the sampler was busy is not owed: the repeating timer is signalled once.
                    int result = (int)waitFor.invokeExact(current, 1000);
                    if (result == 0) return;
                } catch (Throwable failed) { timer = null; }
            }
            LockSupport.parkNanos(this, nanos);
        }
        void close() {
            MemorySegment current = timer;
            timer = null;
            if (current != null) try { int closed = (int)closeHandle.invokeExact(current); } catch (Throwable ignored) { }
        }
    }
}
