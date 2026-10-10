package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.function.LongSupplier;

/**
 * {@code PZToolsAPI.chunks}: a Lua function called when a chunk of the map that covers part of an area a mod registered is loaded
 * (and, if the mod asks, when it is let go), from the frame job on the game's thread (docs/design/extension-api.md, "Chunk
 * watches"), instead of a handler of the game's {@code LoadChunk} event that is called for every chunk and left to find out whether
 * it is one it cares for.
 *
 * <p>The frame job looks at the watched chunks, and only those, {@link #PERIOD_NANOS} apart: each is one lookup in the game's chunk
 * maps ({@code IsoCell.getChunk}) and a read of the chunk's flag that says it is in a map, so a game with no watch costs a check of an
 * empty list, and one with a hundred chunks watched about three microseconds ten times a second. A chunk that is reloaded between
 * two looks (let go and loaded again) is a new chunk, and is told as an unload (if asked) and a load.
 *
 * <p>The watches belong to the world they were made in: leaving it takes them away. They are kept in the API table's metatable, where a
 * newer API takes them over without telling the functions of the chunks that are loaded.
 */
final class ChunkWatches {
    static final int MAX_PER_MOD = 32, MAX_ALL = 128, MAX_CHUNKS = 256, MAX_AREA = 4096, MAX_CALLS_PER_FRAME = 64;
    /** How far apart the looks are. */
    static final long PERIOD_NANOS = 100_000_000L;

    private static final String AREA = "PZToolsAPI.chunks.";
    // In the API's metatable: the watches (id -> record), the number of the next, and which API runs them now.
    private static final String KEPT = "chunkWatches", NEXT = "chunkWatchesNext", GENERATION = "chunkWatchesGeneration";

    /** The clock, in nanoseconds; the tests set it. */
    private LongSupplier clock = System::nanoTime;

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final int chunkSize;
    // IsoCell.getChunk(wx, wy) as (Object, int, int)Object; IsoChunk.loaded.
    private final MethodHandle chunkAt, loaded;

    /** One watch: its chunks (in chunk numbers), and the chunk each held when it was last looked at (null: none loaded). */
    private static final class Watch {
        final long id;
        final String owner;
        final boolean unload;
        final Object function, record, cell;
        final int[] wx, wy;
        final Object[] held;
        final int x, y, w, h;
        boolean cancelled, reported;

        Watch(long id, String owner, boolean unload, Object function, Object record, Object cell, int x, int y, int w, int h, int size) {
            this.id = id; this.owner = owner; this.unload = unload; this.function = function; this.record = record; this.cell = cell;
            this.x = x; this.y = y; this.w = w; this.h = h;
            int firstX = Math.floorDiv(x, size), lastX = Math.floorDiv(x + w - 1, size), firstY = Math.floorDiv(y, size), lastY = Math.floorDiv(y + h - 1, size);
            int count = (lastX - firstX + 1) * (lastY - firstY + 1);
            wx = new int[count]; wy = new int[count]; held = new Object[count];
            int at = 0;
            for (int cy = firstY; cy <= lastY; cy++) for (int cx = firstX; cx <= lastX; cx++) { wx[at] = cx; wy[at] = cy; at++; }
        }
    }

    private final ArrayList<Watch> watches = new ArrayList<>();
    // The changes of the look being made, kept for the next so that a look makes no list.
    private final ArrayList<Change> changes = new ArrayList<>();
    private long next = 1, lastLook;
    private boolean backlog;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private long generation;
    private long calls;
    private boolean reported;

    ChunkWatches(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        chunkSize = Game.type(loader, "zombie.iso.IsoChunkMap").getField("CHUNK_SIZE_IN_SQUARES").getInt(null);
        Class<?> cell = Game.type(loader, "zombie.iso.IsoCell"), chunk = Game.type(loader, "zombie.iso.IsoChunk");
        chunkAt = Game.exact(cell.getMethod("getChunk", int.class, int.class), MethodType.methodType(Object.class, Object.class, int.class, int.class));
        loaded = MethodHandles.publicLookup().unreflectGetter(chunk.getField("loaded")).asType(MethodType.methodType(boolean.class, Object.class));
        world = game.cell();
        lastLook = clock.getAsLong() - PERIOD_NANOS;
        load();
    }

    /** Replaces the clock; the next look is due at once. */
    void clock(LongSupplier replacement) {
        clock = replacement;
        lastLook = replacement.getAsLong() - PERIOD_NANOS;
    }

    /** No watch runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            return body.call(call, arguments);
        }));
    }

    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZToolsAPI");
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        function(table, "watch", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object area = arguments.length > 1 ? arguments[1] : null;
            if (!lua.isTable(area)) throw new IllegalArgumentException(call + ": area must be a table, such as { x = 10500, y = 9700, w = 40, h = 40 }");
            Object function = arguments.length > 2 ? arguments[2] : null;
            if (function == null || function instanceof String || function instanceof Number || function instanceof Boolean || lua.isTable(function))
                throw new IllegalArgumentException(call + ": the third argument must be a function");
            Object options = arguments.length > 3 ? arguments[3] : null;
            if (options != null && !lua.isTable(options)) throw new IllegalArgumentException(call + ": options must be a table");
            int x = whole(area, "x", call, null), y = whole(area, "y", call, null);
            int w = whole(area, "w", call, 1), h = whole(area, "h", call, 1);
            boolean unload = options != null && flag(options, "unload", call, false), current = options == null || flag(options, "current", call, true);
            int own = 0;
            for (Watch watch : watches) if (watch.owner.equals(owner)) own++;
            if (own >= MAX_PER_MOD) throw new IllegalArgumentException(call + ": the mod has " + own + " watches; at most " + MAX_PER_MOD);
            if (watches.size() >= MAX_ALL) throw new IllegalArgumentException(call + ": the mods have " + watches.size() + " watches; at most " + MAX_ALL);
            long chunks = ((long)Math.floorDiv(x + w - 1, chunkSize) - Math.floorDiv(x, chunkSize) + 1) * ((long)Math.floorDiv(y + h - 1, chunkSize) - Math.floorDiv(y, chunkSize) + 1);
            if (chunks > MAX_CHUNKS) throw new IllegalArgumentException(call + ": the area covers " + chunks + " chunks; at most " + MAX_CHUNKS);
            Object record = lua.table();
            Watch watch = new Watch(next++, owner, unload, function, record, game.cell(), x, y, w, h, chunkSize);
            // A chunk loaded now is told as a load at the next look when asked for; otherwise it is simply where the watch starts from.
            if (!current) look(watch, null, game.cell());
            write(watch);
            watches.add(watch);
            lua.set(kept(), (double)watch.id, record);
            lua.set(meta, NEXT, (double)next);
            backlog |= current;
            return new Object[] { (double)watch.id };
        });
        function(table, "unwatch", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object value = arguments.length > 1 ? arguments[1] : null;
            if (!(value instanceof Double number) || number != Math.rint(number) || number < 1)
                throw new IllegalArgumentException(call + ": id must be what watch returned");
            for (Watch watch : watches) if (watch.id == number.longValue() && watch.owner.equals(owner)) { remove(watch); return new Object[] { true }; }
            return new Object[] { false };
        });
    }

    private int whole(Object table, String name, String call, Integer fallback) throws ReflectiveOperationException {
        Object value = lua.get(table, name);
        if (value == null && fallback != null) return fallback;
        return Arguments.integer(new Object[] { value }, 0, call, "area." + name, fallback == null ? -1_000_000 : 1, fallback == null ? 1_000_000 : MAX_AREA);
    }

    private boolean flag(Object options, String name, String call, boolean fallback) throws ReflectiveOperationException {
        Object value = lua.get(options, name);
        if (value == null) return fallback;
        if (!(value instanceof Boolean flag)) throw new IllegalArgumentException(call + ": options." + name + " must be true or false");
        return flag;
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
        return owner;
    }

    /** {@code handle:clear()}: the mod's watches stop. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        for (Watch watch : new ArrayList<>(watches)) if (watch.owner.equals(owner)) remove(watch);
    }

    private void remove(Watch watch) throws ReflectiveOperationException {
        watch.cancelled = true;
        if (watches.remove(watch)) lua.set(kept(), (double)watch.id, null);
    }

    private Object kept() throws ReflectiveOperationException {
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(meta, KEPT, table); }
        return table;
    }

    // ---- kept for a newer API ----

    private void write(Watch watch) throws ReflectiveOperationException {
        Object record = watch.record;
        lua.set(record, "owner", watch.owner);
        lua.set(record, "unload", watch.unload);
        lua.set(record, "function", watch.function);
        lua.set(record, "cell", watch.cell);
        lua.set(record, "x", (double)watch.x);
        lua.set(record, "y", (double)watch.y);
        lua.set(record, "w", (double)watch.w);
        lua.set(record, "h", (double)watch.h);
    }

    /** What an earlier API watched, in this world; the chunks loaded now are where each watch starts from. */
    private void load() throws ReflectiveOperationException {
        if (lua.get(meta, NEXT) instanceof Double number) next = Math.max(next, number.longValue());
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) return;
        for (var entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof Double key) || !lua.isTable(entry.getValue())) continue;
            Object record = entry.getValue();
            if (!(lua.get(record, "owner") instanceof String owner) || lua.get(record, "function") == null
                    || !(lua.get(record, "x") instanceof Double x) || !(lua.get(record, "y") instanceof Double y)
                    || !(lua.get(record, "w") instanceof Double w) || !(lua.get(record, "h") instanceof Double h)) continue;
            Object cell = lua.get(record, "cell");
            if (cell != world) { lua.set(table, key, null); continue; }
            var watch = new Watch(key.longValue(), owner, Boolean.TRUE.equals(lua.get(record, "unload")), lua.get(record, "function"), record, cell,
                x.intValue(), y.intValue(), w.intValue(), h.intValue(), chunkSize);
            try { look(watch, null, world); } catch (ReflectiveOperationException unreadable) { continue; }
            watches.add(watch);
            next = Math.max(next, key.longValue() + 1);
        }
        watches.sort((first, second) -> Long.compare(first.id, second.id));
    }

    // ---- the frame job: on the game's thread ----

    /** A change in a watch's chunk: what it was, to be told to its function. */
    private record Change(Watch watch, boolean load, int wx, int wy) { }

    /** Looks at the watched chunks and calls the functions for those that were loaded or let go; a world left takes its watches away. */
    void frame() {
        if (watches.isEmpty()) return;
        try {
            if (moves.moved()) {
                Object cell = game.cell();
                if (cell != world) {
                    world = cell;
                    for (Watch watch : new ArrayList<>(watches)) if (watch.cell != cell) remove(watch);
                    if (watches.isEmpty()) return;
                }
            }
            long now = clock.getAsLong();
            if (!backlog && now - lastLook < PERIOD_NANOS) return;
            lastLook = now;
            Object cell = game.cell();
            if (cell == null) return;
            changes.clear();
            // A look stops at MAX_CALLS_PER_FRAME changes; the chunks it did not reach are looked at again at once, next frame.
            boolean all = true;
            for (Watch watch : watches) if (!look(watch, changes, cell)) { all = false; break; }
            backlog = !all;
            for (Change change : changes) if (!change.watch().cancelled) call(change);
        } catch (Throwable failure) {
            if (!reported) System.err.println("[PzTools API] chunks: " + failure);
            reported = true;
        }
    }

    /**
     * Looks at the chunks of a watch; with a list, the changes go in it, and without, the chunks are just taken as they are. False
     * when it stopped before the end, the list being full.
     */
    private boolean look(Watch watch, ArrayList<Change> changes, Object cell) throws ReflectiveOperationException {
        for (int index = 0; index < watch.wx.length; index++) {
            if (changes != null && changes.size() >= MAX_CALLS_PER_FRAME) return false;
            Object now;
            try {
                Object chunk = cell == null ? null : (Object)chunkAt.invokeExact(cell, watch.wx[index], watch.wy[index]);
                now = chunk != null && (boolean)loaded.invokeExact(chunk) ? chunk : null;
            } catch (Throwable failure) { throw Game.thrown(failure); }
            Object before = watch.held[index];
            if (now == before) continue;
            watch.held[index] = now;
            if (changes == null) continue;
            if (before != null && watch.unload) changes.add(new Change(watch, false, watch.wx[index], watch.wy[index]));
            if (now != null) changes.add(new Change(watch, true, watch.wx[index], watch.wy[index]));
        }
        return true;
    }

    private void call(Change change) {
        Watch watch = change.watch();
        calls++;
        try {
            Object[] results = lua.call(watch.function, (double)watch.id, change.load() ? "load" : "unload", (double)(change.wx() * chunkSize),
                (double)(change.wy() * chunkSize));
            if (results.length > 0 && !Boolean.TRUE.equals(results[0]) && !watch.reported) {
                watch.reported = true;
                System.err.println("[PzTools API] chunks: the function of watch " + watch.id + " (" + watch.owner + ") failed: "
                    + (results.length > 1 ? results[1] : "unknown"));
            }
        } catch (ReflectiveOperationException | RuntimeException failure) {
            if (!watch.reported) System.err.println("[PzTools API] chunks: the function of watch " + watch.id + " (" + watch.owner + ") could not be called: " + failure);
            watch.reported = true;
        }
    }

    /** How many watches run, and how many functions were called (for the tests). */
    int count() { return watches.size(); }

    long calls() { return calls; }
}
