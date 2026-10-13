package pzext.api;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoWorld;

/**
 * {@code squares.watch} and {@code squares.unwatch}, against the synthetic game: a function called from the frame job when a watched
 * square's properties are taken again from its objects (the hook at the end of {@code IsoGridSquare.RecalcProperties}), once however
 * often it changed, a change made on another thread, a long list spread over frames, the watches gone with their world and taken over
 * by a newer API, and what the hook costs.
 */
final class SquareWatchesTest {
    private static final ClassLoader GAME = SquareWatchesTest.class.getClassLoader();
    private static final List<List<Object>> log = new ArrayList<>();

    private SquareWatchesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            var area = (KahluaTable)api.rawget("squares");
            check(area != null && area.rawget("watch") != null && area.rawget("unwatch") != null, "PZExtAPI.squares is missing");
            Object mod = FormulasTest.call(api, "client", "squares.mod").get(0), second = FormulasTest.call(api, "client", "squares.second").get(0);
            telling(area, mod);
            sharing(area, mod, second);
            offThread(area, mod);
            backlog(area, mod);
            faults(area, mod);
            limits(area, mod, second);
            arguments(area, mod);
            worldLeft(area, mod);
            takeover(api, mod);
            cost(area, mod);
        } finally {
            IsoWorld.instance.setCell(home);
            GameApi.frame(GAME);
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

    private static KahluaTable list(int... numbers) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < numbers.length; index++) table.rawset((Object)(double)(index + 1), (Object)(double)numbers[index]);
        return table;
    }

    private static double watch(KahluaTable area, Object mod, KahluaTable squares, JavaFunction function) {
        return (Double)FormulasTest.call(area, "watch", mod, squares, function).get(0);
    }

    private static void change(int x, int y, int z) { new IsoGridSquare(x, y, z).RecalcProperties(); }

    private static void frame() { GameApi.frame(GAME); }

    /** A watched square that changes is told once at the next frame, however often it changed; others are not. */
    private static void telling(KahluaTable area, Object mod) {
        log.clear();
        double id = watch(area, mod, list(10, 20, 0, 11, 20, 0, 10, 20, 0), record("w"));
        check(id >= 1, "No id was given");
        frame();
        check(log.isEmpty(), "A square was told without a change: " + log);
        change(10, 20, 0);
        check(log.isEmpty(), "A change was told at once, not from the frame job");
        change(10, 20, 0);
        change(12, 20, 0);
        change(10, 20, 1);
        frame();
        check(log.equals(List.of(List.of("w", id, 10.0, 20.0, 0.0))), "The change was not told once, or another square was: " + log);
        frame();
        check(log.size() == 1, "A change was told again: " + log);
        change(11, 20, 0);
        change(10, 20, 0);
        frame();
        check(log.size() == 3 && log.get(1).equals(List.of("w", id, 11.0, 20.0, 0.0)) && log.get(2).equals(List.of("w", id, 10.0, 20.0, 0.0)),
            "The changes were not told in their order: " + log);
        FormulasTest.call(mod, "clear");
        check(GameApi.squares().count() == 0, "The watch outlived clear");
        change(10, 20, 0);
        frame();
        check(log.size() == 3, "A cleared watch was told: " + log);
    }

    /** Two watches of a square are both told; a mod cannot cancel another's; a cancelled watch is not told what it had coming. */
    private static void sharing(KahluaTable area, Object mod, Object second) {
        log.clear();
        double a = watch(area, mod, list(5, 5, 0), record("a")), b = watch(area, second, list(5, 5, 0, 6, 5, 0), record("b"));
        check(a != b, "Two watches have one id");
        change(5, 5, 0);
        frame();
        check(log.size() == 2 && log.get(0).get(0).equals("a") && log.get(1).get(0).equals("b"), "Not both watches were told: " + log);
        check(FormulasTest.call(area, "unwatch", second, a).get(0) == Boolean.FALSE, "A mod cancelled another's watch");
        change(5, 5, 0);
        check(FormulasTest.call(area, "unwatch", mod, a).get(0) == Boolean.TRUE && FormulasTest.call(area, "unwatch", mod, a).get(0) == Boolean.FALSE,
            "unwatch did not answer true once");
        frame();
        check(log.size() == 3 && log.get(2).get(0).equals("b"), "A cancelled watch was told, or the other was not: " + log);
        FormulasTest.call(second, "clear");
        check(GameApi.squares().count() == 0, "The watches were not all stopped");
    }

    /** A chunk loads off the game's thread: its watched square is told at the next frame on the game's thread. */
    private static void offThread(KahluaTable area, Object mod) throws Exception {
        log.clear();
        double id = watch(area, mod, list(7, 7, 0), record("t"));
        Thread loader = new Thread(() -> { for (int n = 0; n < 1000; n++) change(7, 7, 0); });
        loader.start();
        loader.join();
        frame();
        check(log.equals(List.of(List.of("t", id, 7.0, 7.0, 0.0))), "A change on another thread was not told once: " + log);
        FormulasTest.call(mod, "clear");
    }

    /** Many changes at once: 64 a frame, the rest in the next frames, each once. */
    private static void backlog(KahluaTable area, Object mod) {
        log.clear();
        int[] numbers = new int[200 * 3];
        for (int index = 0; index < 200; index++) { numbers[index * 3] = 100 + index; numbers[index * 3 + 1] = 50; }
        watch(area, mod, list(numbers), record("many"));
        for (int index = 0; index < 200; index++) change(100 + index, 50, 0);
        frame();
        check(log.size() == SquareWatches.MAX_CALLS_PER_FRAME, "A frame should call at most 64: " + log.size());
        frame();
        frame();
        frame();
        check(log.size() == 200, "Not every change was told: " + log.size());
        var seen = new HashSet<Object>();
        for (List<Object> call : log) seen.add(call.get(2));
        check(seen.size() == 200, "A square was told twice or missed");
        frame();
        check(log.size() == 200, "Changes were told again");
        FormulasTest.call(mod, "clear");
    }

    /** A function that fails is reported once and the others go on. */
    private static void faults(KahluaTable area, Object mod) {
        log.clear();
        watch(area, mod, list(1, 1, 0), (frame, count) -> { log.add(List.of("failing")); throw new RuntimeException("broken"); });
        watch(area, mod, list(1, 1, 0), record("fine"));
        change(1, 1, 0);
        frame();
        change(1, 1, 0);
        frame();
        check(log.stream().filter(call -> call.get(0).equals("failing")).count() == 2 && log.stream().filter(call -> call.get(0).equals("fine")).count() == 2,
            "A failing function stopped the others: " + log);
        FormulasTest.call(mod, "clear");
    }

    private static void limits(KahluaTable area, Object mod, Object second) {
        for (int index = 0; index < SquareWatches.MAX_PER_MOD; index++) watch(area, mod, list(index, 0, 0), record("x"));
        rejects(area, "at most " + SquareWatches.MAX_PER_MOD, mod, list(0, 1, 0), record("x"));
        FormulasTest.call(mod, "clear");
        int[] numbers = new int[(SquareWatches.MAX_SQUARES + 1) * 3];
        for (int index = 0; index <= SquareWatches.MAX_SQUARES; index++) numbers[index * 3] = index;
        rejects(area, "at most " + SquareWatches.MAX_SQUARES, mod, list(numbers), record("x"));
        numbers = java.util.Arrays.copyOf(numbers, SquareWatches.MAX_SQUARES * 3);
        for (int index = 0; index < SquareWatches.MAX_SQUARES_ALL / SquareWatches.MAX_SQUARES; index++) {
            for (int at = 0; at < SquareWatches.MAX_SQUARES; at++) numbers[at * 3 + 1] = index;
            watch(area, index % 2 == 0 ? mod : second, list(numbers), record("x"));
        }
        rejects(area, "squares; at most " + SquareWatches.MAX_SQUARES_ALL, mod, list(0, 99, 0), record("x"));
        FormulasTest.call(mod, "clear");
        FormulasTest.call(second, "clear");
        check(GameApi.squares().count() == 0, "The watches were not all cleared");
    }

    private static void arguments(KahluaTable area, Object mod) {
        rejects(area, "a handle from PZExtAPI.client", "nope", list(0, 0, 0), record("x"));
        rejects(area, "squares must be a list", mod, "nope", record("x"));
        rejects(area, "squares must be a list", mod, list(0, 0), record("x"));
        rejects(area, "squares must be a list", mod, list(), record("x"));
        rejects(area, "the third argument must be a function", mod, list(0, 0, 0), "nope");
        var fraction = list(0, 0, 0);
        fraction.rawset((Object)2.0, (Object)0.5);
        rejects(area, "squares[2] must be a whole number", mod, fraction, record("x"));
        rejects(area, "squares[3] must be a whole number from -32 to 31", mod, list(0, 0, 32), record("x"));
        rejects(area, "squares[1] must be a whole number", mod, list(SquareWatches.MAX_COORDINATE + 1, 0, 0), record("x"));
        check(GameApi.squares().count() == 0, "A refused watch was made");
        try { FormulasTest.call(area, "unwatch", mod, 0.5); throw new AssertionError("a fraction was taken as an id"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("id must be what watch returned"), expected.getMessage()); }
    }

    private static void rejects(Object table, String message, Object... arguments) {
        try {
            FormulasTest.call(table, "watch", arguments);
            throw new AssertionError("watch took " + java.util.Arrays.toString(arguments));
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
        }
    }

    /** Leaving the world takes its watches away, and lets the hook go. */
    private static void worldLeft(KahluaTable area, Object mod) {
        log.clear();
        watch(area, mod, list(3, 3, 0), record("old"));
        check(GameApi.squares().count() == 1, "The watch is not there");
        IsoWorld.instance.setCell(new IsoCell());
        frame();
        change(3, 3, 0);
        frame();
        check(GameApi.squares().count() == 0 && log.isEmpty(), "A watch outlived its world: " + log);
    }

    /** A newer API takes the watches over and tells their changes; a function a mod kept refuses to be called. */
    private static void takeover(KahluaTable api, Object mod) throws Exception {
        var area = (KahluaTable)api.rawget("squares");
        log.clear();
        double id = watch(area, mod, list(4, 4, 0), record("kept"));
        Object oldWatch = area.rawget("watch");
        GameApi.register(LuaManager.class);
        var next = GameApi.squares();
        check(area.rawget("watch") != oldWatch && next.count() == 1, "The watch was not taken over");
        try { ((JavaFunction)oldWatch).call(new LuaCallFrame(mod, list(0, 0, 0), record("x")), 3); throw new AssertionError("an old function worked"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        change(4, 4, 0);
        frame();
        check(log.equals(List.of(List.of("kept", id, 4.0, 4.0, 0.0))), "The watch did not go on after the takeover: " + log);
        check(FormulasTest.call(area, "unwatch", mod, id).get(0) == Boolean.TRUE, "The watch cannot be cancelled after the takeover");
    }

    /** What the hook costs the game: with nothing watched, and with squares watched elsewhere; printed, and nothing allocated. */
    private static void cost(KahluaTable area, Object mod) {
        log.clear();
        int rounds = 2_000_000;
        for (int warm = 0; warm < rounds; warm++) Hooks.squareChanged(warm & 1023, 9, 0);
        long start = System.nanoTime(), bytes = allocated();
        for (int n = 0; n < rounds; n++) Hooks.squareChanged(n & 1023, 9, 0);
        double none = (System.nanoTime() - start) / (double)rounds;
        long noneBytes = allocated() - bytes;
        int[] numbers = new int[1000 * 3];
        for (int index = 0; index < 1000; index++) { numbers[index * 3] = 5000 + index % 40; numbers[index * 3 + 1] = 5000 + index / 40; }
        watch(area, mod, list(numbers), record("idle"));
        for (int warm = 0; warm < rounds; warm++) Hooks.squareChanged(5000 + (warm & 63), 4990 + (warm & 15), 0);
        start = System.nanoTime();
        bytes = allocated();
        for (int n = 0; n < rounds; n++) Hooks.squareChanged(5000 + (n & 63), 4990 + (n & 15), 0);
        double watched = (System.nanoTime() - start) / (double)rounds;
        long watchedBytes = allocated() - bytes;
        frame();
        System.out.printf("squares: a square change costs %.1f ns with none watched, %.1f ns with 1000 watched near by%n", none, watched);
        check(noneBytes < 1024 && watchedBytes < 1024, "The hook allocated: " + noneBytes + ", " + watchedBytes + " bytes");
        log.clear();
        FormulasTest.call(mod, "clear");
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
