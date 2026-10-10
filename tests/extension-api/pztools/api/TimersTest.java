package pztools.api;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import se.krka.kahlua.integration.LuaCaller;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.iso.IsoCell;
import zombie.iso.IsoWorld;

/**
 * {@code timers.every} and {@code timers.cancel}, against the synthetic game with the clocks in the test's hands: a function called
 * every so many milliseconds or minutes of the world's age, from the frame job, once for the periods a late frame missed.
 */
final class TimersTest {
    private static final ClassLoader GAME = TimersTest.class.getClassLoader();
    private static final long MS = 1_000_000L;
    private static final AtomicLong NOW = new AtomicLong(5_000_000_000_000L);
    private static double minutes = 600;
    private static final List<List<Object>> log = new ArrayList<>();

    private TimersTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        var timers = GameApi.timers();
        var clock = timers.clock;
        var minutesClock = timers.minutesClock;
        timers.clock = NOW::get;
        timers.minutesClock = () -> minutes;
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            var area = (KahluaTable)api.rawget("timers");
            check(area != null && area.rawget("every") != null && area.rawget("cancel") != null, "PZToolsAPI.timers is missing");
            Object mod = FormulasTest.call(api, "client", "timers.mod").get(0), second = FormulasTest.call(api, "client", "timers.second").get(0);
            milliseconds(area, mod);
            gameMinutes(area, mod);
            cancelling(area, mod, second);
            faults(area, mod);
            reentry(area, mod);
            limits(area, mod, second);
            arguments(area, mod);
            worldLeft(area, mod);
            takeover(api, mod);
            cost(area, mod);
        } finally {
            timers = GameApi.timers();
            if (timers != null) { timers.clock = clock; timers.minutesClock = minutesClock; }
            IsoWorld.instance.setCell(home);
        }
    }

    private static JavaFunction record(String name) {
        return (frame, count) -> {
            var call = new ArrayList<Object>();
            call.add(name);
            for (int index = 0; index < count; index++) call.add(frame.get(index));
            log.add(call);
            return 0;
        };
    }

    private static void frames(long ms) {
        NOW.addAndGet(ms * MS);
        GameApi.frame(GAME);
    }

    private static double every(KahluaTable area, Object mod, KahluaTable spec, Object function) {
        return (Double)FormulasTest.call(area, "every", mod, spec, function).get(0);
    }

    private static KahluaTable spec(Object... pairs) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < pairs.length; index += 2) table.rawset(pairs[index], pairs[index + 1]);
        return table;
    }

    /** Called every period of real time, once for the periods a late frame missed; not before. */
    private static void milliseconds(KahluaTable area, Object mod) {
        log.clear();
        double id = every(area, mod, spec("ms", 100.0), record("a"));
        check(id >= 1, "No id was given");
        frames(99);
        check(log.isEmpty(), "A timer was called before its time");
        frames(1);
        check(log.equals(List.of(List.of("a", id, 1.0))), "The timer was not called once at its time: " + log);
        // Frames in between call nothing; the next period.
        frames(50);
        check(log.size() == 1, "The timer was called between periods");
        frames(50);
        check(log.size() == 2 && log.get(1).get(2).equals(1.0), "The second period was not called");
        // A long frame: one call that says how many periods it covers, then back in step.
        frames(340);
        check(log.size() == 3 && log.get(2).get(2).equals(3.0), "A late frame should be one call for 3 periods: " + log);
        frames(50);
        check(log.size() == 3, "The timer was not back in step");
        frames(10);
        check(log.size() == 4 && log.get(3).get(2).equals(1.0), "The timer drifted");
        // The first frame after a registration is not a period.
        log.clear();
        FormulasTest.call(area, "cancel", mod, id);
        double fast = every(area, mod, spec("ms", 1.0), record("fast"));
        frames(0);
        check(log.isEmpty(), "A timer was called in the frame it was made in");
        frames(1);
        check(log.size() == 1, "A 1 ms timer was not called");
        // Once.
        log.clear();
        FormulasTest.call(area, "cancel", mod, fast);
        double once = every(area, mod, spec("ms", 10.0, "once", true), record("once"));
        check(GameApi.timers().count() == 1, "The timer is not kept");
        frames(10);
        frames(10);
        check(log.size() == 1 && GameApi.timers().count() == 0, "A timer made to be called once was called again or kept");
        check(FormulasTest.call(area, "cancel", mod, once).get(0) == Boolean.FALSE, "A timer that went was cancelled");
    }

    /** The world's age in minutes, not the clock: it does not go on while the game is paused. */
    private static void gameMinutes(KahluaTable area, Object mod) {
        log.clear();
        double id = every(area, mod, spec("minutes", 10.0), record("m"));
        frames(1_000_000);
        check(log.isEmpty(), "A timer of game minutes was called with the game's time standing still");
        minutes += 9;
        frames(1);
        check(log.isEmpty(), "A timer of game minutes was called early");
        minutes += 1;
        frames(1);
        check(log.equals(List.of(List.of("m", id, 1.0))), "A timer of game minutes was not called after 10 minutes: " + log);
        // Sped up: one call for the periods the frame covers.
        minutes += 25;
        frames(1);
        check(log.size() == 2 && log.get(1).get(2).equals(2.0), "25 minutes should be 2 periods: " + log);
        minutes += 5;
        frames(1);
        check(log.size() == 3, "The timer lost its step");
        FormulasTest.call(area, "cancel", mod, id);
        minutes += 100;
        frames(1);
        check(log.size() == 3, "A cancelled timer was called");
    }

    private static void cancelling(KahluaTable area, Object mod, Object second) {
        log.clear();
        double a = every(area, mod, spec("ms", 10.0), record("a")), b = every(area, second, spec("ms", 10.0), record("b"));
        check(a != b, "Two timers have one id");
        // Only the mod's own.
        check(FormulasTest.call(area, "cancel", second, a).get(0) == Boolean.FALSE, "A mod cancelled another's timer");
        check(FormulasTest.call(area, "cancel", mod, a).get(0) == Boolean.TRUE && FormulasTest.call(area, "cancel", mod, a).get(0) == Boolean.FALSE,
            "cancel should say whether there was a timer");
        frames(10);
        check(log.size() == 1 && log.get(0).get(0).equals("b"), "A cancelled timer was called, or the other was not: " + log);
        // handle:clear() stops all of a mod's.
        every(area, mod, spec("ms", 10.0), record("c"));
        every(area, mod, spec("minutes", 1.0), record("d"));
        FormulasTest.call(mod, "clear");
        log.clear();
        minutes += 10;
        frames(10);
        check(log.size() == 1 && log.get(0).get(0).equals("b"), "A mod's timers went on after clear: " + log);
        FormulasTest.call(second, "clear");
        check(GameApi.timers().count() == 0, "The timers were not all stopped");
    }

    /** A function that fails is reported once and the timer goes on; the API is not stopped by it. */
    private static void faults(KahluaTable area, Object mod) {
        log.clear();
        var failing = (JavaFunction)(frame, count) -> { log.add(List.of("failing")); throw new IllegalStateException("broken"); };
        double id = every(area, mod, spec("ms", 10.0), failing);
        double fine = every(area, mod, spec("ms", 10.0), record("fine"));
        frames(10);
        frames(10);
        long failed = log.stream().filter(call -> call.get(0).equals("failing")).count();
        check(failed == 2 && log.stream().filter(call -> call.get(0).equals("fine")).count() == 2, "A failing function stopped itself or the others: " + log);
        FormulasTest.call(area, "cancel", mod, id);
        FormulasTest.call(area, "cancel", mod, fine);
    }

    /** A function may make and cancel timers, its own included, as it is called. */
    private static void reentry(KahluaTable area, Object mod) {
        log.clear();
        double[] self = new double[1];
        var other = new double[1];
        self[0] = every(area, mod, spec("ms", 10.0), (JavaFunction)(frame, count) -> {
            log.add(List.of("self"));
            FormulasTest.call(area, "cancel", mod, self[0]);
            FormulasTest.call(area, "cancel", mod, other[0]);
            every(area, mod, spec("ms", 10.0, "once", true), record("born"));
            return 0;
        });
        other[0] = every(area, mod, spec("ms", 10.0), record("other"));
        frames(10);
        check(log.size() == 1 && log.get(0).get(0).equals("self"), "A timer cancelled by another in the same frame was called: " + log);
        frames(10);
        check(log.size() == 2 && log.get(1).get(0).equals("born"), "A timer made by a function was not called: " + log);
        check(GameApi.timers().count() == 0, "Timers were left behind");
    }

    private static void limits(KahluaTable area, Object mod, Object second) {
        for (int index = 0; index < Timers.MAX_PER_MOD; index++) every(area, mod, spec("ms", 1000.0), record("x"));
        rejects(area, "the mod has 64 timers; at most 64", mod, spec("ms", 1000.0), record("x"));
        for (int mods = 0; GameApi.timers().count() < Timers.MAX_ALL; mods++) {
            Object other = FormulasTest.call(GameApiHandles.api(), "client", "timers.filler." + mods).get(0);
            for (int index = 0; index < Timers.MAX_PER_MOD && GameApi.timers().count() < Timers.MAX_ALL; index++) every(area, other, spec("ms", 1000.0), record("x"));
        }
        rejects(area, "the mods have 256 timers; at most 256", second, spec("ms", 1000.0), record("x"));
        for (int mods = 0; mods < 4; mods++) FormulasTest.call(FormulasTest.call(GameApiHandles.api(), "client", "timers.filler." + mods).get(0), "clear");
        FormulasTest.call(mod, "clear");
        check(GameApi.timers().count() == 0, "The timers were not all cleared: " + GameApi.timers().count());
    }

    private static void arguments(KahluaTable area, Object mod) {
        rejects(area, "the first argument must be a handle", null, spec("ms", 10.0), record("x"));
        rejects(area, "spec must be a table", mod, 10.0, record("x"));
        rejects(area, "spec must have ms or minutes, one of them", mod, spec(), record("x"));
        rejects(area, "spec must have ms or minutes, one of them", mod, spec("ms", 10.0, "minutes", 1.0), record("x"));
        rejects(area, "spec.ms must be a number from 1 to 86400000", mod, spec("ms", 0.5), record("x"));
        rejects(area, "spec.ms must be a number from 1 to 86400000", mod, spec("ms", "soon"), record("x"));
        rejects(area, "spec.minutes must be a number from 0.01 to 1440", mod, spec("minutes", 1441.0), record("x"));
        rejects(area, "spec.once must be true or false", mod, spec("ms", 10.0, "once", 1.0), record("x"));
        rejects(area, "the third argument must be a function", mod, spec("ms", 10.0), "x");
        rejects(area, "the third argument must be a function", mod, spec("ms", 10.0), null);
        rejects(area, "the third argument must be a function", mod, spec("ms", 10.0), spec());
        try { FormulasTest.call(area, "cancel", mod, 0.5); throw new AssertionError("cancel accepted 0.5"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("id must be what every returned"), expected.getMessage()); }
    }

    private static void rejects(Object table, String message, Object... arguments) {
        try { FormulasTest.call(table, "every", arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("every accepted bad arguments: " + message);
    }

    /** A world left takes its timers away. */
    private static void worldLeft(KahluaTable area, Object mod) {
        log.clear();
        every(area, mod, spec("ms", 10.0), record("old"));
        check(GameApi.timers().count() == 1, "The timer is not there");
        IsoWorld.instance.setCell(new IsoCell());
        frames(10);
        check(GameApi.timers().count() == 0 && log.isEmpty(), "A timer outlived its world: " + log);
    }

    /** A newer API takes the timers over at the moment they were at; the function a mod kept refuses to be called. */
    private static void takeover(KahluaTable api, Object mod) throws Exception {
        var area = (KahluaTable)api.rawget("timers");
        log.clear();
        double id = every(area, mod, spec("ms", 100.0), record("kept"));
        frames(60);
        Object oldEvery = area.rawget("every");
        GameApi.register(zombie.Lua.LuaManager.class);
        var next = GameApi.timers();
        next.clock = NOW::get;
        next.minutesClock = () -> minutes;
        check(area.rawget("every") != oldEvery && next.count() == 1, "The timer was not taken over");
        try { ((JavaFunction)oldEvery).call(new se.krka.kahlua.vm.LuaCallFrame(mod, spec("ms", 10.0), record("x")), 3); throw new AssertionError("an old function worked"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        frames(39);
        check(log.isEmpty(), "The timer was called early after the takeover");
        frames(1);
        check(log.equals(List.of(List.of("kept", id, 1.0))), "The timer lost its place in the takeover: " + log);
        check(FormulasTest.call(area, "cancel", mod, id).get(0) == Boolean.TRUE, "The timer cannot be cancelled after the takeover");
    }

    /** What a frame costs with timers that are not due, and a due one: printed. */
    private static void cost(KahluaTable area, Object mod) {
        log.clear();
        LuaCaller.calls.clear();
        for (int index = 0; index < 50; index++) every(area, mod, spec("ms", 3_600_000.0), record("idle"));
        for (int index = 0; index < 5; index++) every(area, mod, spec("minutes", 1000.0), record("idle"));
        // The clock moves a little each frame, no timer is due.
        for (int warm = 0; warm < 20000; warm++) { NOW.addAndGet(16 * MS / 10); GameApi.timers().frame(); }
        long bytes = allocated();
        long start = System.nanoTime();
        int rounds = 200_000;
        for (int n = 0; n < rounds; n++) { NOW.addAndGet(16 * MS / 10); GameApi.timers().frame(); }
        long time = System.nanoTime() - start;
        bytes = allocated() - bytes;
        System.out.printf("timers: a frame with 55 timers and none due costs %.1f ns, %d bytes over %d frames%n", time / (double)rounds, bytes, rounds);
        check(bytes < 8192, "Frames with no timer due allocated " + bytes + " bytes");
        check(log.isEmpty(), "A timer was called");
        FormulasTest.call(mod, "clear");
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

    /** The API table the test runs against. */
    static final class GameApiHandles {
        private GameApiHandles() { }

        static KahluaTable api() { return (KahluaTable)zombie.Lua.LuaManager.env.rawget(GameApi.GLOBAL); }
    }
}
