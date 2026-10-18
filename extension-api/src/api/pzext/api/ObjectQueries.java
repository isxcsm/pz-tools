package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.function.DoubleSupplier;
import java.util.concurrent.ThreadLocalRandom;

/**
 * {@code PZExtAPI.objects}: the objects on the squares of an area, found, read by mod data, listed on the edges of a room and taken
 * off their squares, in one call each (docs/design.md, "Objects"). A mod states what it looks for as a table (a {@link ObjectMatch}),
 * read once and kept with the table, and Java walks the squares and their objects through handles: nothing is allocated for a
 * square or an object but the list a call returns.
 *
 * <p>A function a mod keeps from this API refuses to be called once a newer API has taken over ({@link #current}).
 */
final class ObjectQueries {
    private static final String AREA = "PZExtAPI.objects.";
    // In the API's metatable: which API runs the functions now.
    private static final String GENERATION = "objectsGeneration";
    private static final int MAX_COORDINATE = 8_388_607;

    /** The chance a square beyond the inner radius is cleared with; a test sets it. */
    static DoubleSupplier dice = () -> ThreadLocalRandom.current().nextDouble();

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Buildings buildings;
    private final RoomRefs rooms;
    private final ObjectMatch.Handles handles;
    private long generation;
    // The matches read, by the identity of their table; the table is held weakly and a match holds none of it.
    private final WeakHashMap<Object, ObjectMatch> matches = new WeakHashMap<>();

    // IsoGridSquare.getObjects(), has(IsoFlagType), transmitRemoveItemFromSquare(IsoObject), RecalcProperties(), RecalcAllWithNeighbours(boolean).
    private final MethodHandle objectsOf, squareHas, transmit, recalc, recalcAround;
    // IsoObject.hasSpriteGrid(), getFacing(); IsoDoor.getNorth().
    private final MethodHandle hasGrid, facingOf, doorNorth;
    private final Class<?> door;
    private final Object flagNorth, flagWest, facingNorth, facingWest;
    // How an object of a class tells which edge it is on: its getNorth() as a handle, or FACING.
    private static final Object FACING = new Object();
    private final IdentityHashMap<Class<?>, Object> edgers = new IdentityHashMap<>();

    ObjectQueries(Kahlua lua, Game game, Buildings buildings, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.buildings = buildings;
        rooms = new RoomRefs(game, loader);
        handles = new ObjectMatch.Handles(game, loader);
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare"), object = game.objectType;
        Class<?> flag = Game.type(loader, "zombie.iso.SpriteDetails.IsoFlagType"), direction = Game.type(loader, "zombie.iso.IsoDirections");
        MethodType objectOf = MethodType.methodType(Object.class, Object.class);
        objectsOf = Game.exact(square.getMethod("getObjects"), MethodType.methodType(List.class, Object.class));
        squareHas = Game.exact(square.getMethod("has", flag), MethodType.methodType(boolean.class, Object.class, Object.class));
        transmit = Game.exact(square.getMethod("transmitRemoveItemFromSquare", object),
            MethodType.methodType(int.class, Object.class, Object.class));
        recalc = Game.exact(square.getMethod("RecalcProperties"), MethodType.methodType(void.class, Object.class));
        recalcAround = Game.exact(square.getMethod("RecalcAllWithNeighbours", boolean.class),
            MethodType.methodType(void.class, Object.class, boolean.class));
        hasGrid = Game.exact(object.getMethod("hasSpriteGrid"), MethodType.methodType(boolean.class, Object.class));
        facingOf = Game.exact(object.getMethod("getFacing"), objectOf);
        door = Game.type(loader, "zombie.iso.objects.IsoDoor");
        doorNorth = Game.exact(door.getMethod("getNorth"), MethodType.methodType(boolean.class, Object.class));
        flagNorth = constant(flag, "DoorWallN");
        flagWest = constant(flag, "DoorWallW");
        facingNorth = constant(direction, "N");
        facingWest = constant(direction, "W");
    }

    @SuppressWarnings({ "unchecked", "rawtypes" })
    private static Object constant(Class<?> type, String name) { return Enum.valueOf((Class<? extends Enum>)type, name); }

    /** No function of an earlier API may be called any more. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Throwable; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            try { return body.call(call, arguments); }
            catch (Exception | Error failure) { throw failure; }
            catch (Throwable failure) { throw Game.thrown(failure); }
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
        function(table, "find", this::find);
        function(table, "byData", this::byData);
        function(table, "edges", this::edges);
        function(table, "remove", this::remove);
    }

    private static Object argument(Object[] arguments, int index) { return index < arguments.length ? arguments[index] : null; }

    private ObjectMatch match(Object table, String call) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": match must be a table");
        ObjectMatch found = matches.get(table);
        if (found == null) {
            found = ObjectMatch.read(handles, lua, game, table, call);
            matches.put(table, found);
        }
        return found;
    }

    /** The options table, or null; a key that is not one of the call's is the mod's error. */
    private Object options(Object[] arguments, int index, String call, String... allowed) throws ReflectiveOperationException {
        Object value = argument(arguments, index);
        if (value == null) return null;
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": options must be a table");
        for (var entry : lua.entries(value))
            if (!(entry.getKey() instanceof String key) || !List.of(allowed).contains(key))
                throw new IllegalArgumentException(call + ": options." + entry.getKey() + " is not an option (" + String.join(", ", allowed) + ")");
        return value;
    }

    private SquareFilter filter(Object options, String call) throws ReflectiveOperationException {
        Object table = options == null ? null : lua.get(options, "squares");
        return table == null ? null : SquareFilter.read(lua, game, table, call + " (options.squares)");
    }

    private static boolean flag(Kahlua lua, Object options, String key, String call) throws ReflectiveOperationException {
        Object value = options == null ? null : lua.get(options, key);
        if (value != null && !(value instanceof Boolean)) throw new IllegalArgumentException(call + ": options." + key + " must be true or false");
        return Boolean.TRUE.equals(value);
    }

    private List<?> objectsOn(Object square) throws Throwable { return (List<?>)objectsOf.invokeExact(square); }

    // ---- find ----

    private Object[] find(String call, Object[] arguments) throws Throwable {
        Areas.Area area = Areas.read(lua, game, argument(arguments, 0), call);
        ObjectMatch match = match(argument(arguments, 1), call);
        Object options = options(arguments, 2, call, "squares", "limit");
        SquareFilter squares = filter(options, call);
        int limit = Integer.MAX_VALUE;
        if (options != null && lua.get(options, "limit") != null)
            limit = Arguments.integer(new Object[] { lua.get(options, "limit") }, 0, call, "options.limit", 0, Integer.MAX_VALUE);
        var found = new ArrayList<Object>();
        if (limit == 0) return new Object[] { lua.list(found) };
        int most = limit;
        SquareFilter.begin();
        try {
            area.each((square, x, y, z) -> {
                if (squares != null && !squares.test(square)) return true;
                List<?> objects = objectsOn(square);
                for (int at = 0, size = objects.size(); at < size; at++) {
                    Object object = objects.get(at);
                    if (object == null || !match.test(object)) continue;
                    found.add(object);
                    if (found.size() >= most) return false;
                }
                return true;
            });
        } finally { SquareFilter.end(); }
        return new Object[] { lua.list(found) };
    }

    // ---- byData ----

    private Object[] byData(String call, Object[] arguments) throws Throwable {
        String key = Arguments.string(arguments, 0, call, "key");
        Object list = argument(arguments, 1);
        if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": list must be x1, y1, z1, v1, x2, ...");
        int length = lua.length(list);
        if (length % 4 != 0) throw new IllegalArgumentException(call + ": list must be x1, y1, z1, v1, x2, ... (" + length + " values)");
        Object cells = game.cell();
        Object result = lua.table();
        for (int at = 0; at < length; at += 4) {
            int x = coordinate(list, at + 1, call, -MAX_COORDINATE, MAX_COORDINATE), y = coordinate(list, at + 2, call, -MAX_COORDINATE, MAX_COORDINATE);
            int z = coordinate(list, at + 3, call, -32, 31);
            Object wanted = lua.at(list, at + 4);
            if (!(wanted instanceof Double || wanted instanceof String || wanted instanceof Boolean))
                throw new IllegalArgumentException(call + ": list[" + (at + 4) + "] must be a number, string or boolean");
            Object found;
            Object square = game.square(cells, x, y, z);
            if (square == null) found = game.chunkLoaded(cells, game.chunkKey(x, y)) ? Boolean.FALSE : "unloaded";
            else found = withData(square, key, wanted);
            lua.set(result, (double)(at / 4 + 1), found);
        }
        return new Object[] { result };
    }

    private int coordinate(Object list, int at, String call, int low, int high) throws Throwable {
        if (!(lua.at(list, at) instanceof Double number) || number != Math.rint(number) || number < low || number > high)
            throw new IllegalArgumentException(call + ": list[" + at + "] must be a whole number from " + low + " to " + high);
        return number.intValue();
    }

    /** The first object on the square whose mod data holds the value under the key, or false. */
    private Object withData(Object square, String key, Object wanted) throws Throwable {
        List<?> objects = objectsOn(square);
        for (int at = 0, size = objects.size(); at < size; at++) {
            Object object = objects.get(at);
            if (object == null) continue;
            Object data = handles.dataOf(object);
            if (data == null) continue;
            Object held = handles.rawget(data, key);
            if (held == null) continue;
            if (wanted instanceof Double number ? held instanceof Number other && other.doubleValue() == number : wanted.equals(held)) return object;
        }
        return Boolean.FALSE;
    }

    // ---- edges ----

    /** The squares of a room, or of a building's rooms on one level, and a square round them: a mask over that box. */
    private static final class Target {
        final int minX, minY, width, height, z;
        final boolean[] mask;

        Target(int minX, int minY, int width, int height, int z) {
            this.minX = minX; this.minY = minY; this.width = width; this.height = height; this.z = z;
            mask = new boolean[width * height];
        }

        boolean has(int x, int y) {
            int dx = x - minX, dy = y - minY;
            return dx >= 0 && dy >= 0 && dx < width && dy < height && mask[dy * width + dx];
        }
    }

    /** The target a table names ({@code room}, or {@code building} with {@code z}); null when the map has no such room or building now. */
    private Target target(Object table, String call) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": target must be { room = r } or { building = key, z = level }");
        Object room = lua.get(table, "room"), building = lua.get(table, "building");
        if ((room == null) == (building == null))
            throw new IllegalArgumentException(call + ": target must be { room = r } or { building = key, z = level }");
        List<Object> found = new ArrayList<>();
        int z;
        if (room != null) {
            if (!rooms.isRoom(room)) throw new IllegalArgumentException(call + ": target.room must be a room (an IsoRoom, a RoomDef or its id)");
            Object def = rooms.resolve(room);
            if (def == null) return null;
            found.add(def);
            z = buildings.level(def);
        } else {
            if (!(building instanceof String key)) throw new IllegalArgumentException(call + ": target.building must be a building key");
            if (!(lua.get(table, "z") instanceof Double level) || level != Math.rint(level) || level < -32 || level > 31)
                throw new IllegalArgumentException(call + ": target.z must be a whole number from -32 to 31");
            z = level.intValue();
            Buildings.Building known = buildings.resolve(key);
            if (known == null) return null;
            for (Object each : known.rooms()) if (buildings.level(each) == z) found.add(each);
        }
        int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE, maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE;
        var rects = new ArrayList<Buildings.Rect>();
        for (Object each : found) rects.addAll(buildings.rects(each));
        if (rects.isEmpty()) return null;
        for (Buildings.Rect rect : rects) {
            minX = Math.min(minX, rect.x()); minY = Math.min(minY, rect.y());
            maxX = Math.max(maxX, rect.x() + rect.w() - 1); maxY = Math.max(maxY, rect.y() + rect.h() - 1);
        }
        var target = new Target(minX - 1, minY - 1, maxX - minX + 3, maxY - minY + 3, z);
        for (Buildings.Rect rect : rects)
            for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                for (int x = rect.x(); x < rect.x() + rect.w(); x++) target.mask[(y - target.minY) * target.width + x - target.minX] = true;
        return target;
    }

    private Object[] edges(String call, Object[] arguments) throws Throwable {
        Target target = target(argument(arguments, 0), call);
        ObjectMatch match = match(argument(arguments, 1), call);
        Object options = options(arguments, 2, call, "doorways", "outer");
        boolean doorways = flag(lua, options, "doorways", call), outer = flag(lua, options, "outer", call);
        var found = new ArrayList<Object>();
        if (target == null) return new Object[] { lua.list(found) };
        Object cells = game.cell();
        for (int y = target.minY; y < target.minY + target.height; y++) {
            for (int x = target.minX; x < target.minX + target.width; x++) {
                Object square = game.square(cells, x, y, target.z);
                if (square == null) continue;
                List<?> objects = objectsOn(square);
                for (int at = 0, size = objects.size(); at < size; at++) {
                    Object object = objects.get(at);
                    if (object == null || !match.test(object)) continue;
                    int edge = edgeOf(object);
                    if (edge != 0) report(found, target, outer, object, x, y, edge == 1);
                }
                if (doorways) doorways(found, target, outer, square, objects, x, y);
            }
        }
        return new Object[] { lua.list(found) };
    }

    /** 1 for an object on the north edge of its square, 2 for the west edge, 0 for one the game gives no side to. */
    private int edgeOf(Object object) throws Throwable {
        Class<?> type = object.getClass();
        Object how = edgers.get(type);
        if (how == null) {
            how = FACING;
            try {
                var method = type.getMethod("getNorth");
                if (method.getReturnType() == boolean.class && method.getParameterCount() == 0)
                    how = Game.exact(method, MethodType.methodType(boolean.class, Object.class));
            } catch (NoSuchMethodException | IllegalAccessException noSide) { }
            edgers.put(type, how);
        }
        if (how instanceof MethodHandle north) return (boolean)north.invokeExact(object) ? 1 : 2;
        Object facing = (Object)facingOf.invokeExact(object);
        return facing == facingNorth ? 1 : facing == facingWest ? 2 : 0;
    }

    /** The edges flagged as doorways of a square that no door stands on. */
    private void doorways(List<Object> found, Target target, boolean outer, Object square, List<?> objects, int x, int y) throws Throwable {
        boolean north = (boolean)squareHas.invokeExact(square, flagNorth), west = (boolean)squareHas.invokeExact(square, flagWest);
        if (!north && !west) return;
        for (int at = 0, size = objects.size(); at < size; at++) {
            Object object = objects.get(at);
            if (object == null || !door.isInstance(object)) continue;
            if ((boolean)doorNorth.invokeExact(object)) north = false; else west = false;
        }
        if (north) report(found, target, outer, null, x, y, true);
        if (west) report(found, target, outer, null, x, y, false);
    }

    /** Adds the edge of the square (x, y) to the list when one of its sides is in the target and the other is not. */
    private void report(List<Object> found, Target target, boolean outer, Object object, int x, int y, boolean north)
            throws Throwable {
        int ox = north ? x : x - 1, oy = north ? y - 1 : y;
        boolean inside = target.has(x, y);
        if (inside == target.has(ox, oy)) return;
        if (outer && buildings.roomOf(inside ? ox : x, inside ? oy : y, target.z) != null) return;
        Object entry = lua.table();
        if (object != null) lua.set(entry, "object", object);
        lua.set(entry, "x", (double)x);
        lua.set(entry, "y", (double)y);
        lua.set(entry, "z", (double)target.z);
        lua.set(entry, "north", north);
        lua.set(entry, "inside", inside);
        found.add(entry);
    }

    // ---- remove ----

    /** Squares cleared with a chance that falls from 1 at {@code inner} to 0 at {@code outer}. */
    private record Falloff(double x, double y, double inner, double outer) {
        boolean reaches(int sx, int sy) {
            double d = Math.sqrt((sx - x) * (sx - x) + (sy - y) * (sy - y));
            if (d <= inner) return true;
            if (d > outer) return false;
            return dice.getAsDouble() < (outer - d) / (outer - inner);
        }
    }

    private Falloff falloff(Object options, String call) throws ReflectiveOperationException {
        Object table = options == null ? null : lua.get(options, "falloff");
        if (table == null) return null;
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": options.falloff must be { x =, y =, inner =, outer = }");
        double[] values = new double[4];
        String[] names = { "x", "y", "inner", "outer" };
        for (int at = 0; at < 4; at++) {
            if (!(lua.get(table, names[at]) instanceof Double number) || number.isNaN() || number.isInfinite())
                throw new IllegalArgumentException(call + ": options.falloff." + names[at] + " must be a number");
            values[at] = number;
        }
        if (values[2] < 0 || values[3] < values[2])
            throw new IllegalArgumentException(call + ": options.falloff needs 0 <= inner <= outer");
        return new Falloff(values[0], values[1], values[2], values[3]);
    }

    private Object[] remove(String call, Object[] arguments) throws Throwable {
        Areas.Area area = Areas.read(lua, game, argument(arguments, 0), call);
        ObjectMatch match = match(argument(arguments, 1), call);
        Object options = options(arguments, 2, call, "squares", "keep", "falloff");
        SquareFilter squares = filter(options, call);
        Object keepTable = options == null ? null : lua.get(options, "keep");
        ObjectMatch keep = keepTable == null ? null : match(keepTable, call + " (options.keep)");
        Falloff falloff = falloff(options, call);
        // What goes, found first and taken off after: each entry is an object, or all the parts of one that covers several squares.
        var doomed = new ArrayList<Object[]>();
        var decided = new IdentityHashMap<Object, Boolean>();
        SquareFilter.begin();
        try {
            area.each((square, x, y, z) -> {
                if (falloff != null && !falloff.reaches(x, y)) return true;
                if (squares != null && !squares.test(square)) return true;
                List<?> objects = objectsOn(square);
                for (int at = 0, size = objects.size(); at < size; at++) {
                    Object object = objects.get(at);
                    if (object == null || !match.test(object)) continue;
                    if (!(boolean)hasGrid.invokeExact(object)) {
                        if (keep == null || !keep.test(object)) doomed.add(new Object[] { object });
                        continue;
                    }
                    if (decided.containsKey(object)) continue;
                    Object[] parts = game.partsOnThisThread(object).toArray();
                    boolean kept = false;
                    for (Object part : parts) {
                        decided.put(part, Boolean.TRUE);
                        if (keep != null && keep.test(part)) kept = true;
                    }
                    if (!kept) doomed.add(parts);
                }
                return true;
            });
        } finally { SquareFilter.end(); }
        Set<Object> touched = Collections.newSetFromMap(new IdentityHashMap<>());
        var squaresChanged = new ArrayList<Object>();
        for (Object[] group : doomed) {
            for (Object object : group) {
                Object square = (Object)Reach.SQUARE_OF.invokeExact(object);
                if (square == null) continue;
                int index = (int)transmit.invokeExact(square, object);
                if (touched.add(square)) squaresChanged.add(square);
            }
        }
        for (Object square : squaresChanged) {
            recalc.invokeExact(square);
            recalcAround.invokeExact(square, true);
        }
        return new Object[] { (double)doomed.size() };
    }
}
