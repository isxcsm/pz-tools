package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import pzext.api.Buildings.Building;
import pzext.api.Buildings.Rect;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.buildings.watchWalls} and {@code unwatchWalls}: the rooms the walls of a map building make, told to a mod's
 * function when a wall between two of its squares goes up or comes down (docs/design.md, "Wall watches"). The game remakes the
 * rooms of the buildings players build from their walls, never a map building's: a wall taken down leaves two rooms where one
 * stands, a wall built across a room leaves one. What to do with the rooms told (setRooms, or nothing) is the mod's.
 *
 * <p>A watch reads the walls of every square of the building's rooms once, when every chunk the building covers is loaded (it
 * waits until they are, looking now and then), and keeps them as they were last seen. The hook of the square changes
 * ({@code IsoGridSquare.RecalcProperties}, through SquareDispatch: on any thread) asks each watch's box and then the square's
 * slot in it, a table indexed by place: nothing allocated, no hash. The frame job reads the walls of the squares marked; when one
 * differs from what was last seen, it works out the rooms the walls make now, and calls the function when they are not the rooms
 * the building has. Two squares side by side are of one room when they are of the same room unless a wall was built between them
 * since, or of two rooms when the wall between them was taken down since: an open kitchen beside the living room stays the
 * kitchen, and a room with a wall of its own inside stays one room. Then what was seen is what is there now.
 *
 * <p>The watches belong to the world they were made in: leaving it takes them away. They are kept in the API table's metatable,
 * where a newer API takes them over (and reads their walls again).
 */
final class WallWatches implements Hooks.SquareChanges {
    static final int MAX_PER_MOD = 4, MAX_ALL = 16, MAX_SQUARES = 32768;
    /** Frames between two looks at whether a waiting watch's chunks are loaded. */
    static final int WAIT_FRAMES = 30;
    /** A square's walls, as the game's regions tell a room's (IsoRegions.calculateSquareFlags): its north side, its west side. */
    static final int NORTH = 1, WEST = 2;

    private static final String AREA = "PZExtAPI.buildings.";
    // In the API's metatable: the watches (id -> record), the number of the next, and which API runs them now.
    private static final String KEPT = "wallWatches", NEXT = "wallWatchesNext", GENERATION = "wallWatchesGeneration";
    private static final int CHUNKS_WIDE = 13;

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final Object meta;
    private final Networks.Owners owners;
    private final MethodHandle hasFlag, hasType;
    private final Object cutN, cutW, wallSE, doorFrN, doorFrW;
    private final java.lang.reflect.Field gridWidth;

    /** A watched building's squares: its box, each square's slot by place in the box, and what the hook marked. Fixed once made. */
    private static final class Shape {
        final int minX, minY, minZ, width, height, levels;
        final int[] slotAt, xs, ys, zs;
        final boolean[] marked;
        int[] queue = new int[16];
        int queued;

        Shape(int minX, int minY, int minZ, int width, int height, int levels, int[] slotAt, int[] xs, int[] ys, int[] zs) {
            this.minX = minX; this.minY = minY; this.minZ = minZ; this.width = width; this.height = height; this.levels = levels;
            this.slotAt = slotAt; this.xs = xs; this.ys = ys; this.zs = zs;
            marked = new boolean[xs.length];
        }

        /** The slot of the square, or -1 when it is not one of the building's. */
        int slot(int x, int y, int z) {
            int dx = x - minX, dy = y - minY, dz = z - minZ;
            if (dx < 0 || dy < 0 || dz < 0 || dx >= width || dy >= height || dz >= levels) return -1;
            return slotAt[(dz * height + dy) * width + dx];
        }
    }

    /** One watch: its building, its function, and, once its chunks were loaded, its squares and their walls. */
    private static final class Watch {
        final long id;
        final String owner, key;
        final Object function, record, cell;
        volatile Shape shape;
        // The room each square is of (an index into rooms), the rooms' sizes, and the rooms these were read from.
        int[] roomOf;
        int[] sizes;
        List<Object> rooms = List.of();
        int[] levels;
        byte[] before, now;
        int waited;
        boolean cancelled, reported;

        Watch(long id, String owner, String key, Object function, Object record, Object cell) {
            this.id = id; this.owner = owner; this.key = key; this.function = function; this.record = record; this.cell = cell;
        }
    }

    private final ArrayList<Watch> watches = new ArrayList<>();
    // The watches whose squares are read, as the hook goes through them.
    private volatile Watch[] ready = new Watch[0];
    private long next = 1, generation, told;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private boolean reported;

    WallWatches(Kahlua lua, Game game, Buildings buildings, Object meta, Networks.Owners owners, ClassLoader loader)
            throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        this.meta = meta;
        this.owners = owners;
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare");
        Class<?> flag = Game.type(loader, "zombie.iso.SpriteDetails.IsoFlagType");
        Class<?> type = Game.type(loader, "zombie.iso.SpriteDetails.IsoObjectType");
        MethodType ask = MethodType.methodType(boolean.class, Object.class, Object.class);
        hasFlag = Game.exact(square.getMethod("has", flag), ask);
        hasType = Game.exact(square.getMethod("has", type), ask);
        cutN = flag.getField("cutN").get(null);
        cutW = flag.getField("cutW").get(null);
        wallSE = flag.getField("WallSE").get(null);
        doorFrN = type.getField("doorFrN").get(null);
        doorFrW = type.getField("doorFrW").get(null);
        java.lang.reflect.Field width = null;
        try { width = Game.type(loader, "zombie.iso.IsoChunkMap").getField("chunkGridWidth"); }
        catch (ReflectiveOperationException unreadable) { /* the default width */ }
        gridWidth = width;
        world = game.cell();
        load();
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
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** Sets this area's functions into the buildings' table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        function(table, "watchWalls", (call, arguments) -> {
            String owner = owner(arguments, call);
            String key = Arguments.string(arguments, 1, call, "key");
            Object function = arguments.length > 2 ? arguments[2] : null;
            if (function == null || function instanceof String || function instanceof Number || function instanceof Boolean || lua.isTable(function))
                throw new IllegalArgumentException(call + ": the third argument must be a function");
            int own = 0;
            for (Watch watch : watches) if (watch.owner.equals(owner)) own++;
            if (own >= MAX_PER_MOD) throw new IllegalArgumentException(call + ": the mod has " + own + " wall watches; at most " + MAX_PER_MOD);
            if (watches.size() >= MAX_ALL) throw new IllegalArgumentException(call + ": the mods have " + watches.size() + " wall watches; at most " + MAX_ALL);
            Building building = buildings.resolve(key);
            String why = refused(building);
            if (why != null) return new Object[] { null, why };
            Object record = lua.table();
            Watch watch = new Watch(next++, owner, key, function, record, game.cell());
            lua.set(record, "owner", owner);
            lua.set(record, "key", key);
            lua.set(record, "function", function);
            lua.set(record, "cell", watch.cell);
            watches.add(watch);
            lua.set(kept(), (double)watch.id, record);
            lua.set(meta, NEXT, (double)next);
            start(watch, building);
            return new Object[] { (double)watch.id };
        });
        function(table, "unwatchWalls", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object value = arguments.length > 1 ? arguments[1] : null;
            if (!(value instanceof Double number) || number != Math.rint(number) || number < 1)
                throw new IllegalArgumentException(call + ": id must be what watchWalls returned");
            for (Watch watch : watches) {
                if (watch.id == number.longValue() && watch.owner.equals(owner)) {
                    remove(watch);
                    return new Object[] { true };
                }
            }
            return new Object[] { false };
        });
    }

    /** Why a building's walls cannot be watched, or null when they can. */
    private String refused(Building building) throws ReflectiveOperationException {
        if (building == null) return "no building has that key";
        if (building.playerBuilt()) return "the game remakes the rooms of a building players built";
        int span = (loadedChunks() - 1) * game.chunkSize;
        if (building.maxX() - building.minX() + 1 > span || building.maxY() - building.minY() + 1 > span)
            return "the building is larger than the game loads at once";
        long area = 0;
        for (Object room : building.rooms()) for (Rect rect : buildings.rects(room)) area += (long)rect.w() * rect.h();
        if (area > MAX_SQUARES) return "the building's rooms have more than " + MAX_SQUARES + " squares";
        return null;
    }

    private int loadedChunks() {
        try { return gridWidth == null ? CHUNKS_WIDE : Math.max(2, gridWidth.getInt(null)); }
        catch (IllegalAccessException | RuntimeException unreadable) { return CHUNKS_WIDE; }
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
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
        publish();
    }

    private Object kept() throws ReflectiveOperationException {
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(meta, KEPT, table); }
        return table;
    }

    /** What an earlier API watched, in this world: its walls are read again. */
    private void load() throws ReflectiveOperationException {
        if (lua.get(meta, NEXT) instanceof Double number) next = Math.max(next, number.longValue());
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) return;
        for (var entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof Double id) || !lua.isTable(entry.getValue())) continue;
            Object record = entry.getValue();
            if (!(lua.get(record, "owner") instanceof String owner) || !(lua.get(record, "key") instanceof String key)
                    || lua.get(record, "function") == null) continue;
            if (lua.get(record, "cell") != world) { lua.set(table, id, null); continue; }
            watches.add(new Watch(id.longValue(), owner, key, lua.get(record, "function"), record, world));
            next = Math.max(next, id.longValue() + 1);
        }
        watches.sort((first, second) -> Long.compare(first.id, second.id));
    }

    // ---- reading a building ----

    /**
     * Reads the building's squares and their walls once every chunk it covers is loaded; until then the watch waits. A building
     * gone, built by players or grown too large ends the watch.
     */
    private void start(Watch watch, Building building) throws ReflectiveOperationException {
        if (refused(building) != null) { remove(watch); return; }
        Object cells = game.cell();
        if (cells == null) return;
        int size = game.chunkSize;
        for (int cx = Math.floorDiv(building.minX(), size); cx <= Math.floorDiv(building.maxX(), size); cx++)
            for (int cy = Math.floorDiv(building.minY(), size); cy <= Math.floorDiv(building.maxY(), size); cy++)
                if (!game.chunkLoaded(cells, (long)cx << 32 | cy & 0xffffffffL)) return;
        Shape shape = shape(building);
        if (shape == null) { remove(watch); return; }
        byte[] walls = new byte[shape.xs.length];
        for (int slot = 0; slot < walls.length; slot++) {
            Object square = game.square(cells, shape.xs[slot], shape.ys[slot], shape.zs[slot]);
            if (square == null) return; // a square of a loaded chunk not there yet: looked at again later
            walls[slot] = (byte)walls(square);
        }
        if (!rooms(watch, building, shape)) { remove(watch); return; }
        watch.before = walls;
        watch.now = walls.clone();
        watch.shape = shape;
        publish();
    }

    /** The squares of the building's rooms, in the rooms' order; null past MAX_SQUARES, which the rectangles' areas tell first. */
    private Shape shape(Building building) throws ReflectiveOperationException {
        long area = 0;
        int minZ = Integer.MAX_VALUE, maxZ = Integer.MIN_VALUE;
        var roomRects = new ArrayList<List<Rect>>();
        var roomLevels = new int[building.rooms().size()];
        for (int index = 0; index < roomLevels.length; index++) {
            Object room = building.rooms().get(index);
            List<Rect> rects = buildings.rects(room);
            roomRects.add(rects);
            roomLevels[index] = buildings.level(room);
            minZ = Math.min(minZ, roomLevels[index]);
            maxZ = Math.max(maxZ, roomLevels[index]);
            for (Rect rect : rects) area += (long)rect.w() * rect.h();
        }
        if (area > MAX_SQUARES || minZ > maxZ) return null;
        int minX = building.minX(), minY = building.minY();
        int width = building.maxX() - minX + 1, height = building.maxY() - minY + 1, levels = maxZ - minZ + 1;
        int[] slotAt = new int[width * height * levels];
        Arrays.fill(slotAt, -1);
        int[] xs = new int[(int)area], ys = new int[(int)area], zs = new int[(int)area];
        int count = 0;
        for (int index = 0; index < roomLevels.length; index++) {
            int z = roomLevels[index];
            for (Rect rect : roomRects.get(index))
                for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                    for (int x = rect.x(); x < rect.x() + rect.w(); x++) {
                        int place = ((z - minZ) * height + y - minY) * width + x - minX;
                        if (slotAt[place] >= 0) continue;
                        slotAt[place] = count;
                        xs[count] = x; ys[count] = y; zs[count] = z;
                        count++;
                    }
        }
        return new Shape(minX, minY, minZ, width, height, levels, slotAt,
            Arrays.copyOf(xs, count), Arrays.copyOf(ys, count), Arrays.copyOf(zs, count));
    }

    /**
     * Which room each square is of, from the building's rooms now; false when they no longer cover the squares watched (another
     * mod's rooms, of other squares).
     */
    private boolean rooms(Watch watch, Building building, Shape shape) throws ReflectiveOperationException {
        List<Object> rooms = building.rooms();
        int[] roomOf = new int[shape.xs.length], sizes = new int[rooms.size()], levels = new int[rooms.size()];
        Arrays.fill(roomOf, -1);
        int covered = 0;
        for (int index = 0; index < rooms.size(); index++) {
            Object room = rooms.get(index);
            int z = buildings.level(room);
            levels[index] = z;
            for (Rect rect : buildings.rects(room))
                for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                    for (int x = rect.x(); x < rect.x() + rect.w(); x++) {
                        int slot = shape.slot(x, y, z);
                        if (slot < 0) return false;
                        if (roomOf[slot] >= 0) continue;
                        roomOf[slot] = index;
                        sizes[index]++;
                        covered++;
                    }
        }
        if (covered != roomOf.length) return false;
        watch.roomOf = roomOf;
        watch.sizes = sizes;
        watch.levels = levels;
        watch.rooms = rooms;
        return true;
    }

    /** The square's walls (NORTH, WEST): a wall or a window's, a door frame. A corner post (WallSE) leaves the west side open, as there. */
    private int walls(Object square) throws ReflectiveOperationException {
        try {
            int code = (boolean)hasFlag.invokeExact(square, cutN) || (boolean)hasType.invokeExact(square, doorFrN) ? NORTH : 0;
            if (!(boolean)hasFlag.invokeExact(square, wallSE)
                    && ((boolean)hasFlag.invokeExact(square, cutW) || (boolean)hasType.invokeExact(square, doorFrW)))
                code += WEST;
            return code;
        } catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The watches whose squares are read, for the hook; the hook set while there is one, let go with the last. */
    private void publish() {
        var list = new ArrayList<Watch>();
        for (Watch watch : watches) if (watch.shape != null && !watch.cancelled) list.add(watch);
        ready = list.toArray(new Watch[0]);
        if (list.isEmpty()) SquareDispatch.remove(this);
        else SquareDispatch.add(this);
    }

    // ---- the hook: on any thread ----

    @Override
    public void changed(int x, int y, int z) {
        for (Watch watch : ready) {
            Shape shape = watch.shape;
            if (shape == null) continue;
            int slot = shape.slot(x, y, z);
            if (slot < 0) continue;
            synchronized (shape) {
                if (shape.marked[slot]) continue;
                shape.marked[slot] = true;
                if (shape.queued == shape.queue.length) shape.queue = Arrays.copyOf(shape.queue, shape.queued * 2);
                shape.queue[shape.queued++] = slot;
            }
        }
    }

    // ---- the frame job: on the game's thread ----

    /** Reads the walls of the squares that changed, and tells the rooms they make; starts the watches waiting for their chunks. */
    void frame() {
        if (watches.isEmpty()) return;
        try {
            if (moves.moved()) {
                Object cell = game.cell();
                if (cell != world) {
                    world = cell;
                    for (Watch watch : new ArrayList<>(watches)) if (watch.cell != cell) remove(watch);
                }
            }
            for (Watch watch : new ArrayList<>(watches)) {
                if (watch.cancelled) continue;
                if (watch.shape == null) {
                    if (watch.waited++ % WAIT_FRAMES == 0) start(watch, buildings.resolve(watch.key));
                } else {
                    settle(watch);
                }
            }
        } catch (Throwable failure) {
            if (!reported) System.err.println("[PZExt] wall watches: " + failure);
            reported = true;
        }
    }

    private void settle(Watch watch) throws ReflectiveOperationException {
        Shape shape = watch.shape;
        int[] slots;
        int count;
        synchronized (shape) {
            if (shape.queued == 0) return;
            count = shape.queued;
            slots = Arrays.copyOf(shape.queue, count);
            for (int at = 0; at < count; at++) shape.marked[slots[at]] = false;
            shape.queued = 0;
        }
        Object cells = game.cell();
        boolean differs = false;
        for (int at = 0; at < count; at++) {
            int slot = slots[at];
            Object square = game.square(cells, shape.xs[slot], shape.ys[slot], shape.zs[slot]);
            if (square == null) continue;
            watch.now[slot] = (byte)walls(square);
            if (watch.now[slot] != watch.before[slot]) differs = true;
        }
        if (!differs) return;
        Building building = buildings.resolve(watch.key);
        if (refused(building) != null) { remove(watch); return; }
        if (!same(building.rooms(), watch.rooms) && !rooms(watch, building, shape)) {
            // The building's rooms cover other squares now: its squares and walls are read again, as they are.
            watch.shape = null;
            watch.waited = 0;
            publish();
            start(watch, building);
            return;
        }
        Object rooms = partition(watch, shape);
        watch.before = watch.now.clone();
        if (rooms != null) call(watch, rooms);
    }

    private static boolean same(List<Object> first, List<Object> second) {
        if (first.size() != second.size()) return false;
        for (int index = 0; index < first.size(); index++) if (first.get(index) != second.get(index)) return false;
        return true;
    }

    /**
     * The rooms the walls make of the building's squares, as setRooms takes them ({ level, rects }), or null when they are the
     * rooms it has. Two squares side by side are one room when of the same room, unless a wall was built between them since;
     * or of two rooms when the wall between them was taken down since.
     */
    private Object partition(Watch watch, Shape shape) throws ReflectiveOperationException {
        int squares = shape.xs.length;
        int[] parent = new int[squares];
        for (int slot = 0; slot < squares; slot++) parent[slot] = slot;
        for (int slot = 0; slot < squares; slot++) {
            int x = shape.xs[slot], y = shape.ys[slot], z = shape.zs[slot];
            int now = watch.now[slot], was = watch.before[slot];
            int north = shape.slot(x, y - 1, z), west = shape.slot(x - 1, y, z);
            if (north >= 0 && joined(watch, slot, north, (now & NORTH) != 0, (was & NORTH) != 0)) join(parent, slot, north);
            if (west >= 0 && joined(watch, slot, west, (now & WEST) != 0, (was & WEST) != 0)) join(parent, slot, west);
        }
        // The groups in the order of their first square; each the room of its first square, and whether all are of it.
        int[] groupOf = new int[squares], sizes = new int[squares], room = new int[squares];
        boolean[] mixed = new boolean[squares];
        int[] groupAtRoot = new int[squares];
        Arrays.fill(groupAtRoot, -1);
        int groups = 0;
        for (int slot = 0; slot < squares; slot++) {
            int root = find(parent, slot);
            int group = groupAtRoot[root];
            if (group < 0) {
                group = groups++;
                groupAtRoot[root] = group;
                room[group] = watch.roomOf[slot];
            }
            groupOf[slot] = group;
            sizes[group]++;
            if (watch.roomOf[slot] != room[group]) mixed[group] = true;
        }
        boolean changed = groups != watch.sizes.length;
        for (int group = 0; group < groups && !changed; group++)
            if (mixed[group] || sizes[group] != watch.sizes[room[group]]) changed = true;
        if (!changed) return null;
        // Each group's squares as places (y in the high half, x in the low), together and sorted, made into rectangles.
        int[] from = new int[groups + 1];
        for (int group = 0; group < groups; group++) from[group + 1] = from[group] + sizes[group];
        int[] filled = Arrays.copyOf(from, groups);
        long[] places = new long[squares];
        for (int slot = 0; slot < squares; slot++)
            places[filled[groupOf[slot]]++] = (long)shape.ys[slot] << 32 | shape.xs[slot] & 0xFFFFFFFFL;
        var result = new ArrayList<Object>(groups);
        for (int group = 0; group < groups; group++) {
            Arrays.sort(places, from[group], from[group + 1]);
            Object entry = lua.table();
            lua.set(entry, "level", (double)watch.levels[room[group]]);
            var rects = new ArrayList<Object>();
            for (int[] rect : rects(places, from[group], from[group + 1])) {
                Object value = lua.table();
                lua.set(value, "x", (double)rect[0]); lua.set(value, "y", (double)rect[1]);
                lua.set(value, "w", (double)rect[2]); lua.set(value, "h", (double)rect[3]);
                rects.add(value);
            }
            lua.set(entry, "rects", lua.list(rects));
            result.add(entry);
        }
        return lua.list(result);
    }

    /**
     * Squares of one floor as rectangles { x, y, w, h }: runs along x, each grown down while the next row has the same run.
     * places[from, to) are the squares as y << 32 | x, sorted.
     */
    static List<int[]> rects(long[] places, int from, int to) {
        var result = new ArrayList<int[]>();
        var open = new java.util.HashMap<Long, int[]>();
        var now = new java.util.HashMap<Long, int[]>();
        int at = from;
        while (at < to) {
            int y = (int)(places[at] >> 32);
            now.clear();
            while (at < to && (int)(places[at] >> 32) == y) {
                int start = (int)places[at], last = start;
                at++;
                while (at < to && (int)(places[at] >> 32) == y && (int)places[at] == last + 1) { last++; at++; }
                long run = (long)start << 32 | last - start + 1;
                int[] rect = open.get(run);
                if (rect != null && rect[1] + rect[3] == y) rect[3]++;
                else { rect = new int[] { start, y, last - start + 1, 1 }; result.add(rect); }
                now.put(run, rect);
            }
            var swap = open;
            open = now;
            now = swap;
        }
        return result;
    }

    private static boolean joined(Watch watch, int slot, int other, boolean wallNow, boolean wallBefore) {
        if (watch.roomOf[slot] == watch.roomOf[other]) return !(wallNow && !wallBefore);
        return wallBefore && !wallNow;
    }

    private static int find(int[] parent, int slot) {
        int root = slot;
        while (parent[root] != root) root = parent[root];
        while (slot != root) {
            int up = parent[slot];
            parent[slot] = root;
            slot = up;
        }
        return root;
    }

    private static void join(int[] parent, int first, int second) {
        int a = find(parent, first), b = find(parent, second);
        if (a != b) parent[a] = b;
    }

    private void call(Watch watch, Object rooms) {
        told++;
        try {
            Object[] results = lua.call(watch.function, watch.key, rooms);
            if (results.length > 0 && !Boolean.TRUE.equals(results[0]) && !watch.reported) {
                watch.reported = true;
                System.err.println("[PZExt] wall watches: the function of watch " + watch.id + " (" + watch.owner + ") failed: "
                    + (results.length > 1 ? results[1] : "unknown"));
            }
        } catch (ReflectiveOperationException | RuntimeException failure) {
            if (!watch.reported) System.err.println("[PZExt] wall watches: the function of watch " + watch.id + " (" + watch.owner + ") could not be called: " + failure);
            watch.reported = true;
        }
    }

    /** How many watches run, how many have read their walls, and how many times a function was told (for the tests). */
    int count() { return watches.size(); }

    int ready() { return ready.length; }

    long told() { return told; }
}
