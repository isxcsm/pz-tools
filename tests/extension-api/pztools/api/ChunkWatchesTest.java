package pztools.api;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.iso.IsoCell;
import zombie.iso.IsoChunk;
import zombie.iso.IsoWorld;

/**
 * {@code chunks.watch} and {@code chunks.unwatch}, against the synthetic game with the clock in the test's hands: a function called
 * when a chunk under an area is loaded (or let go, if asked), from the frame job, looking ten times a second, a long list of changes
 * spread over frames, and the watches gone with their world.
 */
final class ChunkWatchesTest {
    private static final ClassLoader GAME = ChunkWatchesTest.class.getClassLoader();
    private static final long PERIOD = ChunkWatches.PERIOD_NANOS;
    private static final AtomicLong NOW = new AtomicLong(9_000_000_000_000L);
    private static final List<List<Object>> log = new ArrayList<>();
    private static IsoCell cell;

    private ChunkWatchesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        var watching = GameApi.chunks();
        watching.clock(NOW::get);
        try {
            cell = new IsoCell();
            IsoWorld.instance.setCell(cell);
            GameApi.frame(GAME);
            var area = (KahluaTable)api.rawget("chunks");
            check(area != null && area.rawget("watch") != null && area.rawget("unwatch") != null, "PZToolsAPI.chunks is missing");
            Object mod = FormulasTest.call(api, "client", "chunks.mod").get(0), second = FormulasTest.call(api, "client", "chunks.second").get(0);
            loading(area, mod);
            unloading(area, mod);
            notCurrent(area, mod);
            cancelling(area, mod, second);
            faults(area, mod);
            backlog(area, mod);
            limits(area, mod, second);
            arguments(area, mod);
            worldLeft(area, mod);
            takeover(api, mod);
            cost(area, mod);
        } finally {
            watching = GameApi.chunks();
            if (watching != null) watching.clock(System::nanoTime);
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

    private static IsoChunk chunk(int wx, int wy, boolean loaded) {
        var chunk = new IsoChunk(wx, wy);
        chunk.cell = cell;
        chunk.loaded = loaded;
        cell.chunks.put(wx + "," + wy, chunk);
        return chunk;
    }

    /** One frame, a look's time after the last. */
    private static void look() {
        NOW.addAndGet(PERIOD);
        GameApi.frame(GAME);
    }

    private static KahluaTable table(Object... pairs) {
        var table = new KahluaTableImpl();
        for (int index = 0; index < pairs.length; index += 2) table.rawset(pairs[index], pairs[index + 1]);
        return table;
    }

    private static double watch(KahluaTable area, Object mod, KahluaTable spec, Object function, Object... options) {
        return (Double)FormulasTest.call(area, "watch", mod, spec, function, options.length == 0 ? null : options[0]).get(0);
    }

    private static KahluaTable box(int x, int y, int w, int h) { return table("x", (double)x, "y", (double)y, "w", (double)w, "h", (double)h); }

    /** The chunks that are loaded already are told at once; the others when they come, at the next look. */
    private static void loading(KahluaTable area, Object mod) {
        log.clear();
        chunk(3, 2, true);
        // Squares 24..39 by 16..23: the chunks (3,2) and (4,2).
        double id = watch(area, mod, box(24, 16, 16, 8), record("w"));
        check(id >= 1, "No id was given");
        GameApi.frame(GAME);
        check(log.equals(List.of(List.of("w", id, "load", 24.0, 16.0))), "A chunk loaded when the watch began was not told: " + log);
        // Nothing between looks, and nothing for what is the same.
        look();
        look();
        check(log.size() == 1, "A chunk that did not change was told again: " + log);
        chunk(4, 2, true);
        // Not looked at yet: a look's time has not passed.
        NOW.addAndGet(PERIOD / 2);
        GameApi.frame(GAME);
        check(log.size() == 1, "A chunk was told before the next look");
        NOW.addAndGet(PERIOD / 2);
        GameApi.frame(GAME);
        check(log.size() == 2 && log.get(1).equals(List.of("w", id, "load", 32.0, 16.0)), "The chunk that came was not told: " + log);
        // A chunk the cell lists but that is not in a chunk map yet is not loaded.
        chunk(4, 2, false);
        look();
        check(log.size() == 2, "A chunk not in a map was told as an unload without being asked");
        chunk(4, 2, true);
        look();
        check(log.size() == 3 && log.get(2).get(2).equals("load"), "A chunk that came back was not told: " + log);
        // Outside the area: not told.
        chunk(9, 9, true);
        look();
        check(log.size() == 3, "A chunk outside the area was told");
        FormulasTest.call(area, "unwatch", mod, id);
    }

    private static void unloading(KahluaTable area, Object mod) {
        log.clear();
        double id = watch(area, mod, box(24, 16, 8, 8), record("u"), table("unload", true));
        look();
        check(log.equals(List.of(List.of("u", id, "load", 24.0, 16.0))), "The first load was not told: " + log);
        cell.chunks.get("3,2").loaded = false;
        look();
        check(log.size() == 2 && log.get(1).equals(List.of("u", id, "unload", 24.0, 16.0)), "A chunk let go was not told: " + log);
        // Loaded again as a new chunk, and let go and loaded between two looks: an unload and a load.
        chunk(3, 2, true);
        look();
        check(log.size() == 3 && log.get(2).get(2).equals("load"), "A chunk loaded again was not told: " + log);
        chunk(3, 2, true);
        look();
        check(log.size() == 5 && log.get(3).get(2).equals("unload") && log.get(4).get(2).equals("load"),
            "A chunk reloaded between two looks should be an unload and a load: " + log);
        // Without the option no unload is told, and the load after it is.
        FormulasTest.call(area, "unwatch", mod, id);
        log.clear();
        double quiet = watch(area, mod, box(24, 16, 8, 8), record("q"));
        look();
        cell.chunks.get("3,2").loaded = false;
        look();
        chunk(3, 2, true);
        look();
        check(log.size() == 2 && log.stream().allMatch(call -> call.get(2).equals("load")), "A watch without unload was told of an unload: " + log);
        FormulasTest.call(area, "unwatch", mod, quiet);
    }

    /** current = false: the chunks loaded when the watch is made are where it starts from. */
    private static void notCurrent(KahluaTable area, Object mod) {
        log.clear();
        cell.chunks.get("3,2").loaded = true;
        double id = watch(area, mod, box(24, 16, 16, 8), record("n"), table("current", false));
        look();
        look();
        check(log.isEmpty(), "A chunk loaded when the watch began was told with current = false: " + log);
        chunk(5, 2, true);
        FormulasTest.call(area, "unwatch", mod, id);
        double wide = watch(area, mod, box(24, 16, 24, 8), record("n"), table("current", false));
        look();
        check(log.isEmpty(), "Chunks loaded at the start were told: " + log);
        chunk(5, 2, false);
        look();
        chunk(5, 2, true);
        look();
        check(log.size() == 1 && log.get(0).equals(List.of("n", wide, "load", 40.0, 16.0)), "A chunk that came after the start was not told: " + log);
        FormulasTest.call(area, "unwatch", mod, wide);
    }

    private static void cancelling(KahluaTable area, Object mod, Object second) {
        log.clear();
        cell.chunks.clear();
        double a = watch(area, mod, box(0, 0, 8, 8), record("a")), b = watch(area, second, box(0, 0, 8, 8), record("b"));
        check(a != b, "Two watches have one id");
        check(FormulasTest.call(area, "unwatch", second, a).get(0) == Boolean.FALSE, "A mod cancelled another's watch");
        check(FormulasTest.call(area, "unwatch", mod, a).get(0) == Boolean.TRUE && FormulasTest.call(area, "unwatch", mod, a).get(0) == Boolean.FALSE,
            "unwatch should say whether there was a watch");
        chunk(0, 0, true);
        look();
        check(log.size() == 1 && log.get(0).get(0).equals("b"), "A cancelled watch was called, or the other was not: " + log);
        watch(area, mod, box(0, 0, 8, 8), record("c"));
        FormulasTest.call(mod, "clear");
        check(GameApi.chunks().count() == 1, "A mod's watches went on after clear");
        FormulasTest.call(second, "clear");
        check(GameApi.chunks().count() == 0, "The watches were not all stopped");
    }

    private static void faults(KahluaTable area, Object mod) {
        log.clear();
        cell.chunks.clear();
        double id = watch(area, mod, box(0, 0, 8, 8), (JavaFunction)(frame, count) -> { log.add(List.of("failing")); throw new IllegalStateException("broken"); });
        double fine = watch(area, mod, box(0, 0, 8, 8), record("fine"));
        chunk(0, 0, true);
        look();
        chunk(0, 0, true);
        look();
        check(log.stream().filter(call -> call.get(0).equals("failing")).count() == 2 && log.stream().filter(call -> call.get(0).equals("fine")).count() == 2,
            "A failing function stopped itself or the others: " + log);
        FormulasTest.call(area, "unwatch", mod, id);
        FormulasTest.call(area, "unwatch", mod, fine);
    }

    /** A long list of changes is called 64 a frame, in order, with no look between them; none is lost. */
    private static void backlog(KahluaTable area, Object mod) {
        log.clear();
        cell.chunks.clear();
        // 16 by 16 chunks: 256, the most one area may cover.
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) chunk(x, y, true);
        watch(area, mod, box(0, 0, 128, 128), record("big"));
        GameApi.frame(GAME);
        check(log.size() == ChunkWatches.MAX_CALLS_PER_FRAME, "A frame should call at most 64: " + log.size());
        GameApi.frame(GAME);
        check(log.size() == 2 * ChunkWatches.MAX_CALLS_PER_FRAME, "The rest was not called the next frame without waiting: " + log.size());
        GameApi.frame(GAME);
        GameApi.frame(GAME);
        check(log.size() == 256, "Not every chunk was told: " + log.size());
        var seen = new java.util.HashSet<List<Object>>();
        for (var call : log) seen.add(List.of(call.get(3), call.get(4)));
        check(seen.size() == 256, "A chunk was told twice or missed");
        GameApi.frame(GAME);
        look();
        check(log.size() == 256, "Chunks were told again");
        FormulasTest.call(mod, "clear");
    }

    private static void limits(KahluaTable area, Object mod, Object second) throws Exception {
        for (int index = 0; index < ChunkWatches.MAX_PER_MOD; index++) watch(area, mod, box(0, 0, 8, 8), record("x"));
        rejects(area, "the mod has 32 watches; at most 32", mod, box(0, 0, 8, 8), record("x"));
        for (int mods = 0; GameApi.chunks().count() < ChunkWatches.MAX_ALL; mods++) {
            Object other = FormulasTest.call(api(), "client", "chunks.filler." + mods).get(0);
            for (int index = 0; index < ChunkWatches.MAX_PER_MOD && GameApi.chunks().count() < ChunkWatches.MAX_ALL; index++) watch(area, other, box(0, 0, 8, 8), record("x"));
        }
        rejects(area, "the mods have 128 watches; at most 128", second, box(0, 0, 8, 8), record("x"));
        for (int mods = 0; mods < 4; mods++) FormulasTest.call(FormulasTest.call(api(), "client", "chunks.filler." + mods).get(0), "clear");
        FormulasTest.call(mod, "clear");
        check(GameApi.chunks().count() == 0, "The watches were not all cleared");
        rejects(area, "the area covers 289 chunks; at most 256", mod, box(0, 0, 136, 136), record("x"));
    }

    private static KahluaTable api() { return (KahluaTable)LuaManager.env.rawget(GameApi.GLOBAL); }

    private static void arguments(KahluaTable area, Object mod) {
        rejects(area, "the first argument must be a handle", null, box(0, 0, 8, 8), record("x"));
        rejects(area, "area must be a table", mod, 5.0, record("x"));
        rejects(area, "area.x must be a whole number", mod, table("y", 0.0), record("x"));
        rejects(area, "area.y must be a whole number", mod, table("x", 0.0, "y", 1.5), record("x"));
        rejects(area, "area.w must be a whole number from 1 to 4096", mod, table("x", 0.0, "y", 0.0, "w", 0.0), record("x"));
        rejects(area, "area.h must be a whole number from 1 to 4096", mod, table("x", 0.0, "y", 0.0, "h", 5000.0), record("x"));
        rejects(area, "the third argument must be a function", mod, box(0, 0, 8, 8), "x");
        rejects(area, "the third argument must be a function", mod, box(0, 0, 8, 8), null);
        rejects(area, "options must be a table", mod, box(0, 0, 8, 8), record("x"), 5.0);
        rejects(area, "options.unload must be true or false", mod, box(0, 0, 8, 8), record("x"), table("unload", 1.0));
        rejects(area, "options.current must be true or false", mod, box(0, 0, 8, 8), record("x"), table("current", "yes"));
        // A one square area is a chunk; negative squares are chunks too.
        double id = watch(area, mod, table("x", -1.0, "y", -1.0), record("x"));
        check(id >= 1 && GameApi.chunks().count() == 1, "A one square area was refused");
        try { FormulasTest.call(area, "unwatch", mod, 0.5); throw new AssertionError("unwatch accepted 0.5"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("id must be what watch returned"), expected.getMessage()); }
        FormulasTest.call(mod, "clear");
    }

    private static void rejects(Object table, String message, Object... arguments) {
        try { FormulasTest.call(table, "watch", arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError("watch accepted bad arguments: " + message);
    }

    private static void worldLeft(KahluaTable area, Object mod) {
        log.clear();
        cell.chunks.clear();
        watch(area, mod, box(0, 0, 8, 8), record("old"));
        check(GameApi.chunks().count() == 1, "The watch is not there");
        cell = new IsoCell();
        IsoWorld.instance.setCell(cell);
        chunk(0, 0, true);
        look();
        check(GameApi.chunks().count() == 0 && log.isEmpty(), "A watch outlived its world: " + log);
    }

    /** A newer API takes the watches over; the chunks loaded then are not told again, and a function a mod kept refuses to be called. */
    private static void takeover(KahluaTable api, Object mod) throws Exception {
        var area = (KahluaTable)api.rawget("chunks");
        log.clear();
        cell.chunks.clear();
        chunk(0, 0, true);
        double id = watch(area, mod, box(0, 0, 16, 8), record("kept"));
        look();
        check(log.size() == 1, "The chunk was not told");
        Object oldWatch = area.rawget("watch");
        GameApi.register(LuaManager.class);
        var next = GameApi.chunks();
        next.clock(NOW::get);
        check(area.rawget("watch") != oldWatch && next.count() == 1, "The watch was not taken over");
        try { ((JavaFunction)oldWatch).call(new LuaCallFrame(mod, box(0, 0, 8, 8), record("x")), 3); throw new AssertionError("an old function worked"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        look();
        check(log.size() == 1, "The chunk loaded before the takeover was told again: " + log);
        chunk(1, 0, true);
        look();
        check(log.size() == 2 && log.get(1).equals(List.of("kept", id, "load", 8.0, 0.0)), "The watch did not go on after the takeover: " + log);
        check(FormulasTest.call(area, "unwatch", mod, id).get(0) == Boolean.TRUE, "The watch cannot be cancelled after the takeover");
    }

    /** What looks cost: printed, and nothing allocated when nothing changed. */
    private static void cost(KahluaTable area, Object mod) {
        log.clear();
        cell.chunks.clear();
        for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) chunk(x, y, true);
        for (int index = 0; index < 32; index++) watch(area, mod, box((index % 4) * 32, (index / 4) * 8 % 64, 32, 8), record("idle"));
        for (int warm = 0; warm < 5000; warm++) look();
        log.clear();
        long bytes = allocated();
        long start = System.nanoTime();
        int rounds = 100_000;
        for (int n = 0; n < rounds; n++) look();
        long time = System.nanoTime() - start;
        bytes = allocated() - bytes;
        System.out.printf("chunks: a look at 32 watches (%d chunks) costs %.0f ns, %d bytes a look%n", 32 * 4, time / (double)rounds, bytes / rounds);
        check(log.isEmpty(), "A chunk was told");
        // The synthetic cell builds a key to find a chunk (the game's does not): what it allocates alone is taken off.
        long base = allocated();
        for (int n = 0; n < rounds; n++) for (int c = 0; c < 128; c++) cell.getChunk(c % 16, c / 16 % 8);
        base = allocated() - base;
        check(bytes - base < 64L * rounds, "Looks with no change allocated " + (bytes - base) + " bytes beyond the cell's own lookups");
        // Frames between looks cost a clock read.
        start = System.nanoTime();
        for (int n = 0; n < rounds; n++) { NOW.addAndGet(1000); GameApi.chunks().frame(); }
        System.out.printf("chunks: a frame between looks costs %.1f ns%n", (System.nanoTime() - start) / (double)rounds);
        FormulasTest.call(mod, "clear");
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
