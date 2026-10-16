package pzext.api;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import pzext.api.Network.Position;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.squares}: a Lua function called when the objects of a square a mod watches change (docs/design.md, "Square
 * watches"), from the frame job on the game's thread, instead of a mod looking at its squares again and again for what was built on
 * them or taken away.
 *
 * <p>The game works a square's properties out again from its objects ({@code IsoGridSquare.RecalcProperties}) whenever one is put
 * on it or taken off, its floor changes, a wall goes up or down beside it, or it loads; the hook there asks the index of the watched
 * squares (an immutable {@link SquareMap}, a box test and a hash probe, safe on the threads that load chunks) and only a watched
 * square goes further: it is marked once and queued. With nothing watched the hook is not set and the game's call costs a null test.
 * The frame job hands the queued squares to the functions of the watches that hold them, at most {@link #MAX_CALLS_PER_FRAME} a frame.
 *
 * <p>The watches belong to the world they were made in: leaving it takes them away. They are kept in the API table's metatable, where a
 * newer API takes them over.
 */
final class SquareWatches implements Hooks.SquareChanges {
    static final int MAX_PER_MOD = 32, MAX_ALL = 128, MAX_SQUARES = 16384, MAX_SQUARES_ALL = 65536, MAX_CALLS_PER_FRAME = 64;
    static final int MAX_LEVEL = 31, MIN_LEVEL = -32, MAX_COORDINATE = 8_388_607;

    private static final String AREA = "PZExtAPI.squares.";
    // In the API's metatable: the watches (id -> record), the number of the next, and which API runs them now.
    private static final String KEPT = "squareWatches", NEXT = "squareWatchesNext", GENERATION = "squareWatchesGeneration";

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;

    /** One watch: its squares. */
    private static final class Watch {
        final long id;
        final String owner;
        final Object function, record, cell;
        final int[] xs, ys, zs;
        boolean cancelled, reported;

        Watch(long id, String owner, Object function, Object record, Object cell, int[] xs, int[] ys, int[] zs) {
            this.id = id; this.owner = owner; this.function = function; this.record = record; this.cell = cell;
            this.xs = xs; this.ys = ys; this.zs = zs;
        }
    }

    /**
     * The watched squares as the hook reads them: each square's slot, its place and the watches holding it, and what was marked since
     * the frame job last took it (guarded by the index itself; only a watched square that changed takes the lock).
     */
    private static final class Index {
        final SquareMap slots;
        final int[] xs, ys, zs;
        final Watch[][] holders;
        final boolean[] marked;
        int[] queue = new int[16];
        int queued;

        Index(SquareMap slots, int[] xs, int[] ys, int[] zs, Watch[][] holders) {
            this.slots = slots; this.xs = xs; this.ys = ys; this.zs = zs; this.holders = holders;
            marked = new boolean[xs.length];
        }
    }

    /** A change to tell a watch's function. */
    private record Call(Watch watch, int x, int y, int z) { }

    private final ArrayList<Watch> watches = new ArrayList<>();
    private volatile Index index;
    // What is still to be told, in order; a long list is told over several frames.
    private final ArrayList<Call> calls = new ArrayList<>();
    private int told;
    private long next = 1, generation, made;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private boolean reported;

    SquareWatches(Kahlua lua, Game game, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        world = game.cell();
        load();
        reindex();
    }

    /** No watch runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    /** The hook is let go (a newer API, or a failure): the game's call costs a null test again. */
    static void unhook() {
        SquareDispatch.clear();
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
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        function(table, "watch", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object list = arguments.length > 1 ? arguments[1] : null;
            if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": squares must be a list x1, y1, z1, x2, y2, z2, ...");
            Object function = arguments.length > 2 ? arguments[2] : null;
            if (function == null || function instanceof String || function instanceof Number || function instanceof Boolean || lua.isTable(function))
                throw new IllegalArgumentException(call + ": the third argument must be a function");
            int own = 0, squares = 0;
            for (Watch watch : watches) {
                if (watch.owner.equals(owner)) own++;
                squares += watch.xs.length;
            }
            if (own >= MAX_PER_MOD) throw new IllegalArgumentException(call + ": the mod has " + own + " watches; at most " + MAX_PER_MOD);
            if (watches.size() >= MAX_ALL) throw new IllegalArgumentException(call + ": the mods have " + watches.size() + " watches; at most " + MAX_ALL);
            int[][] read = squares(list, call);
            if (squares + read[0].length > MAX_SQUARES_ALL)
                throw new IllegalArgumentException(call + ": the mods would watch " + (squares + read[0].length) + " squares; at most " + MAX_SQUARES_ALL);
            Object record = lua.table();
            Watch watch = new Watch(next++, owner, function, record, game.cell(), read[0], read[1], read[2]);
            lua.set(record, "owner", owner);
            lua.set(record, "function", function);
            lua.set(record, "cell", watch.cell);
            lua.set(record, "squares", list);
            watches.add(watch);
            lua.set(kept(), (double)watch.id, record);
            lua.set(meta, NEXT, (double)next);
            reindex();
            return new Object[] { (double)watch.id };
        });
        function(table, "unwatch", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object value = arguments.length > 1 ? arguments[1] : null;
            if (!(value instanceof Double number) || number != Math.rint(number) || number < 1)
                throw new IllegalArgumentException(call + ": id must be what watch returned");
            for (Watch watch : watches) {
                if (watch.id == number.longValue() && watch.owner.equals(owner)) {
                    remove(watch);
                    reindex();
                    return new Object[] { true };
                }
            }
            return new Object[] { false };
        });
    }

    /** The squares of a list x1, y1, z1, ...: their x, y and z; a square named twice is watched once. */
    private int[][] squares(Object list, String call) throws ReflectiveOperationException {
        int length;
        try { length = lua.length(list); } catch (Throwable failure) { throw Game.thrown(failure); }
        if (length < 3 || length % 3 != 0) throw new IllegalArgumentException(call + ": squares must be a list x1, y1, z1, x2, y2, z2, ...");
        if (length / 3 > MAX_SQUARES) throw new IllegalArgumentException(call + ": " + length / 3 + " squares; at most " + MAX_SQUARES);
        var seen = new LinkedHashMap<Position, Boolean>();
        for (int at = 1; at <= length; at += 3) {
            int x = coordinate(list, at, call, -MAX_COORDINATE, MAX_COORDINATE), y = coordinate(list, at + 1, call, -MAX_COORDINATE, MAX_COORDINATE);
            int z = coordinate(list, at + 2, call, MIN_LEVEL, MAX_LEVEL);
            seen.put(new Position(x, y, z), Boolean.TRUE);
        }
        int[] xs = new int[seen.size()], ys = new int[seen.size()], zs = new int[seen.size()];
        int at = 0;
        for (Position square : seen.keySet()) { xs[at] = square.x(); ys[at] = square.y(); zs[at] = square.z(); at++; }
        return new int[][] { xs, ys, zs };
    }

    private int coordinate(Object list, int at, String call, int low, int high) throws ReflectiveOperationException {
        Object value = lua.get(list, (double)at);
        if (!(value instanceof Double number) || number != Math.rint(number) || number < low || number > high)
            throw new IllegalArgumentException(call + ": squares[" + at + "] must be a whole number from " + low + " to " + high);
        return number.intValue();
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
        return owner;
    }

    /** {@code handle:clear()}: the mod's watches stop. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        boolean any = false;
        for (Watch watch : new ArrayList<>(watches)) if (watch.owner.equals(owner)) { remove(watch); any = true; }
        if (any) reindex();
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

    /** What an earlier API watched, in this world. */
    private void load() throws ReflectiveOperationException {
        if (lua.get(meta, NEXT) instanceof Double number) next = Math.max(next, number.longValue());
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) return;
        for (var entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof Double key) || !lua.isTable(entry.getValue())) continue;
            Object record = entry.getValue();
            Object list = lua.get(record, "squares");
            if (!(lua.get(record, "owner") instanceof String owner) || lua.get(record, "function") == null || !lua.isTable(list)) continue;
            if (lua.get(record, "cell") != world) { lua.set(table, key, null); continue; }
            int[][] read;
            try { read = squares(list, AREA + "watch"); } catch (IllegalArgumentException unreadable) { continue; }
            watches.add(new Watch(key.longValue(), owner, lua.get(record, "function"), record, world, read[0], read[1], read[2]));
            next = Math.max(next, key.longValue() + 1);
        }
        watches.sort((first, second) -> Long.compare(first.id, second.id));
    }

    // ---- the index, built on the game's thread ----

    /** The index made again from the watches; what the old one marked is kept to be told; the hook set or let go. */
    private void reindex() {
        take(index);
        if (watches.isEmpty()) {
            index = null;
            SquareDispatch.remove(this);
            return;
        }
        var slots = new HashMap<Position, Long>();
        var held = new ArrayList<ArrayList<Watch>>();
        for (Watch watch : watches) {
            for (int at = 0; at < watch.xs.length; at++) {
                var square = new Position(watch.xs[at], watch.ys[at], watch.zs[at]);
                Long slot = slots.get(square);
                if (slot == null) { slot = (long)held.size(); slots.put(square, slot); held.add(new ArrayList<>()); }
                held.get(slot.intValue()).add(watch);
            }
        }
        int size = held.size();
        int[] xs = new int[size], ys = new int[size], zs = new int[size];
        Watch[][] holders = new Watch[size][];
        for (var entry : slots.entrySet()) {
            int slot = entry.getValue().intValue();
            xs[slot] = entry.getKey().x(); ys[slot] = entry.getKey().y(); zs[slot] = entry.getKey().z();
            holders[slot] = held.get(slot).toArray(new Watch[0]);
        }
        index = new Index(new SquareMap(slots), xs, ys, zs, holders);
        SquareDispatch.add(this);
    }

    // ---- the hook: on any thread ----

    @Override
    public void changed(int x, int y, int z) {
        Index current = index;
        if (current == null) return;
        long slot = current.slots.get(x, y, z, -1);
        if (slot < 0) return;
        synchronized (current) {
            int at = (int)slot;
            if (current.marked[at]) return;
            current.marked[at] = true;
            if (current.queued == current.queue.length) current.queue = java.util.Arrays.copyOf(current.queue, current.queued * 2);
            current.queue[current.queued++] = at;
        }
    }

    // ---- the frame job: on the game's thread ----

    /** The squares an index marked, to be told to the watches that hold them. */
    private void take(Index from) {
        if (from == null) return;
        int[] slots;
        int count;
        synchronized (from) {
            if (from.queued == 0) return;
            slots = java.util.Arrays.copyOf(from.queue, from.queued);
            count = from.queued;
            for (int at = 0; at < count; at++) from.marked[slots[at]] = false;
            from.queued = 0;
        }
        for (int at = 0; at < count; at++) {
            int slot = slots[at];
            for (Watch watch : from.holders[slot]) calls.add(new Call(watch, from.xs[slot], from.ys[slot], from.zs[slot]));
        }
    }

    /** Tells the watches' functions of their squares that changed; a world left takes its watches away. */
    void frame() {
        if (watches.isEmpty() && calls.isEmpty()) return;
        try {
            if (moves.moved()) {
                Object cell = game.cell();
                if (cell != world) {
                    world = cell;
                    boolean any = false;
                    for (Watch watch : new ArrayList<>(watches)) if (watch.cell != cell) { remove(watch); any = true; }
                    if (any) reindex();
                }
            }
            take(index);
            int stop = Math.min(calls.size(), told + MAX_CALLS_PER_FRAME);
            while (told < stop) {
                Call change = calls.get(told++);
                if (!change.watch().cancelled) call(change);
            }
            if (told == calls.size()) { calls.clear(); told = 0; }
        } catch (Throwable failure) {
            if (!reported) System.err.println("[PZExt] squares: " + failure);
            reported = true;
        }
    }

    private void call(Call change) {
        Watch watch = change.watch();
        made++;
        try {
            Object[] results = lua.call(watch.function, (double)watch.id, (double)change.x(), (double)change.y(), (double)change.z());
            if (results.length > 0 && !Boolean.TRUE.equals(results[0]) && !watch.reported) {
                watch.reported = true;
                System.err.println("[PZExt] squares: the function of watch " + watch.id + " (" + watch.owner + ") failed: "
                    + (results.length > 1 ? results[1] : "unknown"));
            }
        } catch (ReflectiveOperationException | RuntimeException failure) {
            if (!watch.reported) System.err.println("[PZExt] squares: the function of watch " + watch.id + " (" + watch.owner + ") could not be called: " + failure);
            watch.reported = true;
        }
    }

    /** How many watches run, and how many functions were called (for the tests). */
    int count() { return watches.size(); }

    long calls() { return made; }
}
