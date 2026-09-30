package pztools.bridge.runtime;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.IdentityHashMap;
import java.util.concurrent.locks.LockSupport;
import jdk.jfr.*;

/**
 * One recording at a time, started and stopped on request. Nothing is sampled, hooked or kept
 * while no recording runs.
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

    /** Innermost first, as {@code name|file|line} joined by tabs-free separators; see {@link LuaSampler}. */
    @Name("pztools.LuaSample") @Label("Lua sample") @Category("PZ Tools") @StackTrace(false)
    static final class LuaSampleEvent extends Event { @Label("Stack") String stack; }

    @Name("pztools.LuaSampler") @Label("Lua sampler") @Category("PZ Tools") @StackTrace(false)
    static final class LuaSamplerEvent extends Event {
        @Label("Samples taken") long taken;
        @Label("Samples in Lua") long inLua;
        @Label("Period in microseconds") long periodMicros;
    }

    static final int MAXIMUM_SECONDS = 1800;
    private static volatile Recording recording;
    private static LuaSampler lua;
    private static Thread luaThread;
    private static long startedNanos;
    private static boolean detailed;
    private static String luaState = "not-started";
    private static volatile boolean active;
    private static volatile long frames;
    // Game thread only while active.
    private static FrameEvent open;

    private ProfileRecorder() { }

    static boolean active() { return active; }
    /** Any thread: whether the flight recorder is still taking events; it ends by itself at the maximum duration. */
    static boolean running() {
        Recording current = recording;
        return active && current != null && current.getState() == RecordingState.RUNNING;
    }

    /** Game thread, once per game-loop iteration. One branch when nothing is being recorded. */
    static void frame() {
        if (!active) return;
        FrameEvent previous = open;
        if (previous != null) { previous.end(); previous.commit(); }
        FrameEvent next = new FrameEvent();
        next.begin();
        open = next;
        frames++;
    }

    static synchronized String start(Path destination, boolean detailedMode, int maximumSeconds, ClassLoader gameLoader) throws Exception {
        if (active && recording != null && recording.getState() == RecordingState.RUNNING) throw new IllegalStateException("already-recording");
        closeQuietly();
        if (!destination.isAbsolute() || !destination.getFileName().toString().endsWith(".jfr")
                || !Files.isDirectory(destination.getParent()))
            throw new IllegalArgumentException("An absolute .jfr path in an existing directory is required");
        if (maximumSeconds < 5 || maximumSeconds > MAXIMUM_SECONDS) throw new IllegalArgumentException("Invalid maximum duration");
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
            next.setDumpOnExit(true);
            next.setMaxSize(512L * 1024 * 1024);
            next.setDuration(Duration.ofSeconds(maximumSeconds));
            next.setDestination(destination);
            TimerResolution.raise();
            next.start();
        } catch (Throwable failure) { TimerResolution.restore(); next.close(); throw failure; }
        recording = next; detailed = detailedMode; startedNanos = System.nanoTime(); frames = 0; open = null;
        LuaSampler sampler = null;
        try { sampler = new LuaSampler(gameLoader, detailedMode ? 1_000_000L : 10_000_000L); luaState = "sampling"; }
        catch (ReflectiveOperationException | LinkageError unavailable) { luaState = "unavailable:" + unavailable.getClass().getSimpleName(); }
        lua = sampler;
        if (sampler != null) {
            luaThread = new Thread(sampler, "PzTools-lua-sampler");
            luaThread.setDaemon(true);
            luaThread.start();
        }
        active = true;
        return status();
    }

    static synchronized String stop() throws Exception {
        if (recording == null) throw new IllegalStateException("not-recording");
        String result = status();
        active = false;
        open = null;
        stopLua();
        Recording current = recording;
        recording = null;
        try { if (current.getState() == RecordingState.RUNNING) current.stop(); }
        finally { current.close(); TimerResolution.restore(); }
        return result;
    }

    /** {@code state;elapsedMillis;frames;mode;lua} - fixed fields, no free text. */
    static synchronized String status() {
        boolean running = recording != null && recording.getState() == RecordingState.RUNNING;
        // The recorder ends a recording by itself at its maximum duration; that is "finished", not lost.
        String state = recording == null ? "idle" : running ? "recording" : "finished";
        long elapsed = recording == null ? 0 : (System.nanoTime() - startedNanos) / 1_000_000L;
        return state + ";" + elapsed + ";" + frames + ";" + (detailed ? "detailed" : "general") + ";" + luaState;
    }

    /** Payload replacement or shutdown: leave nothing running that belongs to a retiring class loader. */
    static synchronized void closeQuietly() {
        active = false; open = null;
        stopLua();
        Recording current = recording;
        recording = null;
        if (current != null) try { current.close(); } catch (Throwable ignored) { }
        TimerResolution.restore();
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
        private final Field[] threads;
        private final Field currentCoroutine, closure, pc, prototype, name, file, filename, lines;
        private final Method top, stack;
        private final long periodNanos;
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
            threads = ui == null ? new Field[] { main } : new Field[] { main, ui };
            currentCoroutine = typed(kahlua.getField("currentCoroutine"), coroutine);
            top = coroutine.getMethod("getCallframeTop");
            stack = coroutine.getMethod("getCallframeStack");
            if (top.getReturnType() != int.class || stack.getReturnType() != frame.arrayType()) throw new NoSuchMethodException("Coroutine call frames");
            closure = typed(frame.getField("closure"), closureType);
            pc = typed(frame.getField("pc"), int.class);
            prototype = typed(closureType.getField("prototype"), prototypeType);
            name = typed(prototypeType.getField("name"), String.class);
            file = typed(prototypeType.getField("file"), String.class);
            filename = typed(prototypeType.getField("filename"), String.class);
            lines = typed(prototypeType.getField("lines"), int[].class);
        }
        private static Field typed(Field field, Class<?> type) throws NoSuchFieldException {
            if (field.getType() != type) throw new NoSuchFieldException(field.getName());
            return field;
        }

        @Override public void run() {
            long taken = 0, inLua = 0, lastReport = System.nanoTime();
            var text = new StringBuilder(512);
            try {
                while (!stopped) {
                    wait.pause(periodNanos);
                    if (stopped) break;
                    taken++;
                    // The recording ended by itself: stop reading the game for nobody.
                    if ((taken & 255) == 0 && !ProfileRecorder.running()) break;
                    text.setLength(0);
                    try { read(text); } catch (Throwable racing) { text.setLength(0); }
                    if (text.length() != 0) {
                        inLua++;
                        LuaSampleEvent event = new LuaSampleEvent();
                        event.stack = text.toString();
                        event.commit();
                    }
                    long now = System.nanoTime();
                    if (now - lastReport >= 1_000_000_000L) {
                        report(taken, inLua); taken = inLua = 0; lastReport = now;
                    }
                }
                report(taken, inLua);
            } finally { wait.close(); }
        }
        private void report(long taken, long inLua) {
            LuaSamplerEvent event = new LuaSamplerEvent();
            event.taken = taken; event.inLua = inLua; event.periodMicros = periodNanos / 1000;
            event.commit();
        }

        private void read(StringBuilder out) throws ReflectiveOperationException {
            for (Field thread : threads) {
                Object interpreter = thread.get(null);
                if (interpreter == null) continue;
                Object coroutine = currentCoroutine.get(interpreter);
                if (coroutine == null) continue;
                int depth = (int)top.invoke(coroutine);
                Object[] frames = (Object[])stack.invoke(coroutine);
                if (depth <= 0 || frames == null) continue;
                int written = 0;
                for (int index = Math.min(depth, frames.length) - 1; index >= 0 && written < MAXIMUM_DEPTH; index--) {
                    Object callFrame = frames[index];
                    if (callFrame == null) continue;
                    Object function = closure.get(callFrame);
                    if (function == null) continue; // A Java function called from Lua; the Java samples cover it.
                    Object code = prototype.get(function);
                    if (code == null) continue;
                    String label = labels.get(code);
                    if (label == null) {
                        if (labels.size() >= MAXIMUM_CACHE) labels.clear();
                        label = clean((String)name.get(code)) + "|" + clean(firstNonEmpty((String)filename.get(code), (String)file.get(code)));
                        labels.put(code, label);
                    }
                    int line = 0, counter = pc.getInt(callFrame) - 1;
                    int[] lineTable = (int[])lines.get(code);
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
        void pause(long nanos) {
            MemorySegment current = timer;
            if (current != null) {
                try {
                    due.set(ValueLayout.JAVA_LONG, 0, -Math.max(1, nanos / 100));
                    int armed = (int)setTimer.invokeExact(current, due, 0, MemorySegment.NULL, MemorySegment.NULL, 0);
                    if (armed != 0) {
                        int result = (int)waitFor.invokeExact(current, 1000);
                        if (result == 0) return;
                    }
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
