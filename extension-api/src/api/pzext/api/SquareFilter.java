package pzext.api;

import static pzext.api.SquareFacts.*;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * A condition table read once (docs/design.md, "Conditions on a square"): its keys compiled into a small array of checks, cheap
 * ones first, that a square must all meet. A table is read once and the filter kept with it, weakly, so that a mod that keeps its
 * tables as constants pays for reading them once; nothing the filter holds refers to the table.
 *
 * <p>A square is asked through method handles that are constants of the compiled code, and nothing is allocated for it. The
 * conditions that look at other squares ({@code around}, {@code clear}) and the shapes of {@code squares.fit} ask the same squares
 * again and again, so while a query runs ({@link #begin} to {@link #end}) what a filter said of a square is kept in a small table
 * of its own, valid for that query only; outside a query nothing is kept. Used on the game's thread only.
 */
final class SquareFilter {
    /** One condition. {@code anchor} is the square a shape is placed at, or null (see {@code room = "anchor"}). */
    @FunctionalInterface private interface Check { boolean test(Object square, Object anchor) throws Throwable; }

    /** A check and how dear it is: the cheap ones go first, so that most squares fail early. */
    private record Ranked(int rank, Check check) { }

    static final int MAX_CLEAR = 32;
    private static final SquareFilter ALL = new SquareFilter(new Check[0], false);
    private static final Map<Object, SquareFilter> CACHE = new WeakHashMap<>();
    // The queries running (begin and end nest) and the number of the outermost one: what a filter remembered is of that one only.
    private static int depth, epoch;
    // What filters remember of squares, one table for all of them (valid for the epoch it was written in, and for the filter that wrote it),
    // made when first needed and kept: a query allocates nothing for it, however many tables it reads.
    private static final int MEMO_BITS = 14;
    private static long[] memoKeys;
    private static int[] memoEpochs, memoFilters;
    private static boolean[] memoResults;
    private static int filters;

    private final Check[] checks;
    private final boolean usesAnchor;
    // Tells this filter's memory from another's in the shared table.
    private final int id = ++filters;

    private SquareFilter(Check[] checks, boolean usesAnchor) {
        this.checks = checks;
        this.usesAnchor = usesAnchor;
    }

    /** A query starts: what filters remember of squares is kept until {@link #end}. Always paired, in a finally. */
    static void begin() { if (depth++ == 0) epoch++; }

    static void end() { if (depth > 0) depth--; }

    /**
     * The filter a condition table says; a table not read before is read now. {@code table} nil is a filter that every loaded square
     * meets. A wrong key or value is an IllegalArgumentException that names {@code call}.
     */
    static SquareFilter read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (table == null) return ALL;
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": filter must be a table of conditions, or nil");
        synchronized (CACHE) {
            SquareFilter known = CACHE.get(table);
            if (known != null) return known;
        }
        SquareFilter made;
        try { made = compile(lua, table, call, "filter"); }
        catch (RuntimeException | Error | ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
        synchronized (CACHE) { CACHE.put(table, made); }
        return made;
    }

    /** Whether the loaded square meets every condition. For a condition that is {@code room = "anchor"}, see {@link #test(Object, Object)}. */
    boolean test(Object square) throws Throwable { return test(square, null); }

    /** As {@link #test(Object)}, for a square of a shape placed at {@code anchor} (a loaded square): {@code room = "anchor"} means its room. */
    boolean test(Object square, Object anchor) throws Throwable {
        for (Check check : checks) if (!check.test(square, anchor)) return false;
        return true;
    }

    /** Whether some condition is {@code room = "anchor"}, which only a shape placed at an anchor can answer. */
    boolean usesAnchor() { return usesAnchor; }

    /** Whether the square at x, y, z is loaded and meets every condition; remembered for the query running. */
    boolean passesAt(Object cell, int x, int y, int z, Object anchor) throws Throwable {
        if (depth == 0 || usesAnchor) {
            Object square = (Object)Reach.GRID_SQUARE.invokeExact(cell, x, y, z);
            return square != null && test(square, anchor);
        }
        if (memoKeys == null) {
            memoKeys = new long[1 << MEMO_BITS]; memoEpochs = new int[1 << MEMO_BITS]; memoFilters = new int[1 << MEMO_BITS]; memoResults = new boolean[1 << MEMO_BITS];
        }
        long key = (long)(x & 0xFFFFFF) << 30 | (long)(y & 0xFFFFFF) << 6 | z + 32 & 63;
        int slot = (int)((key + id * 0x632BE59BD9B4E019L) * 0x9E3779B97F4A7C15L >>> 64 - MEMO_BITS);
        if (memoEpochs[slot] == epoch && memoKeys[slot] == key && memoFilters[slot] == id) return memoResults[slot];
        Object square = (Object)Reach.GRID_SQUARE.invokeExact(cell, x, y, z);
        boolean met = square != null && test(square, anchor);
        memoKeys[slot] = key;
        memoEpochs[slot] = epoch;
        memoFilters[slot] = id;
        memoResults[slot] = met;
        return met;
    }

    // ---- reading a table ----

    private static SquareFilter compile(Kahlua lua, Object table, String call, String path) throws Throwable {
        var found = new ArrayList<Ranked>();
        boolean[] anchored = { false };
        for (Map.Entry<Object, Object> entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof String key)) throw new IllegalArgumentException(call + ": " + path + " has a key that is not a name");
            Object value = entry.getValue();
            String name = path + "." + key;
            switch (key) {
                case "free" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(1, (s, a) -> (boolean)IS_FREE.invokeExact(s, false) == want));
                }
                case "solidFloor" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(0, (s, a) -> (boolean)SOLID_FLOOR.invokeExact(s) == want));
                }
                case "floor" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(1, (s, a) -> ((Object)FLOOR.invokeExact(s) != null) == want));
                }
                case "floorPrefix" -> {
                    String[] prefixes = strings(lua, value, call, name);
                    found.add(new Ranked(2, (s, a) -> {
                        Object floor = (Object)FLOOR.invokeExact(s);
                        String sprite = floor == null ? null : spriteName(floor);
                        if (sprite == null) return false;
                        for (String prefix : prefixes) if (sprite.startsWith(prefix)) return true;
                        return false;
                    }));
                }
                case "floorAvoid" -> {
                    String[] avoided = strings(lua, value, call, name);
                    found.add(new Ranked(2, (s, a) -> {
                        Object floor = (Object)FLOOR.invokeExact(s);
                        String sprite = floor == null ? null : spriteName(floor);
                        if (sprite == null) return true;
                        for (String part : avoided) if (sprite.contains(part)) return false;
                        return true;
                    }));
                }
                case "water" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(0, (s, a) -> (boolean)WATER_SQUARE.invokeExact(s) == want));
                }
                case "waterFlag" -> {
                    boolean want = bool(value, call, name);
                    Object flag = flag("water", call, name);
                    found.add(new Ranked(0, (s, a) -> (boolean)HAS_FLAG.invokeExact(s, flag) == want));
                }
                case "outside" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(0, (s, a) -> (boolean)OUTSIDE.invokeExact(s) == want));
                }
                case "room" -> {
                    Check room = room(value, call, name);
                    if (value instanceof String text && text.equals("anchor")) anchored[0] = true;
                    found.add(new Ranked(1, room));
                }
                case "building" -> found.add(new Ranked(1, building(value, call, name)));
                case "stairs" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(0, (s, a) -> (boolean)STAIRS.invokeExact(s) == want));
                }
                case "tree" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(0, (s, a) -> (boolean)TREE.invokeExact(s) == want));
                }
                case "vehicle" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(1, (s, a) -> ((boolean)VEHICLE_OVER.invokeExact(s) || (Object)VEHICLE_ON.invokeExact(s) != null) == want));
                }
                case "moving" -> {
                    boolean want = bool(value, call, name);
                    found.add(new Ranked(1, (s, a) -> (!((List<?>)MOVING.invokeExact(s)).isEmpty()) == want));
                }
                case "doorEdge" -> found.add(new Ranked(3, doorEdge(bool(value, call, name), call, name)));
                case "flags", "noFlags" -> {
                    String[] names = strings(lua, value, call, name);
                    Object[] wanted = new Object[names.length];
                    for (int at = 0; at < names.length; at++) wanted[at] = flag(names[at], call, name);
                    boolean all = key.equals("flags");
                    found.add(new Ranked(0, (s, a) -> {
                        for (Object flag : wanted) if ((boolean)HAS_FLAG.invokeExact(s, flag) != all) return false;
                        return true;
                    }));
                }
                case "noObjectData" -> {
                    if (!(value instanceof String data)) throw new IllegalArgumentException(call + ": " + name + " must be a mod data key");
                    found.add(new Ranked(3, (s, a) -> {
                        List<?> objects = (List<?>)OBJECTS.invokeExact(s);
                        for (int at = 0, size = objects.size(); at < size; at++) {
                            Object object = objects.get(at);
                            if ((boolean)HAS_DATA.invokeExact(object) && (Object)RAWGET.invokeExact((Object)DATA.invokeExact(object), (Object)data) != null)
                                return false;
                        }
                        return true;
                    }));
                }
                case "zonesNot" -> found.add(new Ranked(3, zonesNot(strings(lua, value, call, name))));
                case "around" -> {
                    SquareFilter inner = nested(lua, value, call, name);
                    if (inner.usesAnchor) anchored[0] = true;
                    found.add(new Ranked(4, (s, a) -> around(s, inner, a)));
                }
                case "clear" -> {
                    if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": " + name + " must be { r = n, filter = {...} }");
                    Object radius = lua.get(value, "r"), within = lua.get(value, "filter");
                    for (Map.Entry<Object, Object> option : lua.entries(value))
                        if (!"r".equals(option.getKey()) && !"filter".equals(option.getKey()))
                            throw new IllegalArgumentException(call + ": " + name + "." + option.getKey() + " is not r or filter");
                    int r = whole(radius, call, name + ".r", 0, MAX_CLEAR);
                    SquareFilter inner = within == null ? ALL : nested(lua, within, call, name + ".filter");
                    if (inner.usesAnchor) anchored[0] = true;
                    found.add(new Ranked(4, (s, a) -> clear(s, r, inner, a)));
                }
                case "distance" -> found.add(new Ranked(0, distance(lua, value, call, name)));
                default -> throw new IllegalArgumentException(call + ": " + name + " is not a condition");
            }
        }
        if (found.isEmpty()) return ALL;
        found.sort((first, second) -> Integer.compare(first.rank(), second.rank()));
        Check[] checks = new Check[found.size()];
        for (int at = 0; at < checks.length; at++) checks[at] = found.get(at).check();
        return new SquareFilter(checks, anchored[0]);
    }

    private static SquareFilter nested(Kahlua lua, Object table, String call, String name) throws Throwable {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": " + name + " must be a table of conditions");
        return compile(lua, table, call, name);
    }

    private static boolean bool(Object value, String call, String name) {
        if (!(value instanceof Boolean flag)) throw new IllegalArgumentException(call + ": " + name + " must be true or false");
        return flag;
    }

    private static int whole(Object value, String call, String name, int min, int max) {
        if (!(value instanceof Double number) || number != Math.rint(number) || number < min || number > max)
            throw new IllegalArgumentException(call + ": " + name + " must be a whole number from " + min + " to " + max);
        return number.intValue();
    }

    private static String[] strings(Kahlua lua, Object value, String call, String name) throws Throwable {
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": " + name + " must be a list of strings");
        int length = lua.length(value);
        String[] result = new String[length];
        for (int at = 0; at < length; at++) {
            if (!(lua.at(value, at + 1) instanceof String text)) throw new IllegalArgumentException(call + ": " + name + "[" + (at + 1) + "] must be a string");
            result[at] = text;
        }
        return result;
    }

    /** An IsoFlagType constant by name. */
    private static Object flag(String name, String call, String path) {
        for (Object constant : FLAG.getEnumConstants()) if (((Enum<?>)constant).name().equals(name)) return constant;
        throw new IllegalArgumentException(call + ": " + path + " names " + name + ", which is not a flag of the game (IsoFlagType)");
    }

    /** The id a value names a room by: an IsoRoom, its RoomDef, or a room's id as {@code buildings} gives it. */
    static long roomId(Object value, String call, String name) throws Throwable {
        if (ROOM_TYPE.isInstance(value)) {
            Object def = (Object)ROOM_DEF.invokeExact(value);
            if (def == null) throw new IllegalArgumentException(call + ": " + name + " is a room without a definition");
            return (long)ROOM_ID.invokeExact(def);
        }
        if (ROOM_DEF_TYPE.isInstance(value)) return (long)ROOM_ID.invokeExact(value);
        if (value instanceof Double number && number == Math.rint(number)) return number.longValue();
        if (value instanceof String text) {
            try { return Long.parseLong(text); }
            catch (NumberFormatException notAnId) { /* said below */ }
        }
        throw new IllegalArgumentException(call + ": " + name + " must be a room (IsoRoom or RoomDef) or a room's id as buildings gives it");
    }

    private static Check room(Object value, String call, String name) throws Throwable {
        if ("none".equals(value)) return (s, a) -> (Object)ROOM.invokeExact(s) == null;
        if ("any".equals(value)) return (s, a) -> (Object)ROOM.invokeExact(s) != null;
        if ("anchor".equals(value)) return (s, a) -> {
            if (a == null) throw new IllegalStateException(call + ": " + name + " = \"anchor\" is for the parts of squares.fit");
            return (Object)ROOM.invokeExact(s) == (Object)ROOM.invokeExact(a);
        };
        long id = roomId(value, call, name);
        return (s, a) -> roomIdOf(s) == id;
    }

    /** A building condition: none, any, or one building by its key, looked for again whenever the game's buildings changed. */
    private static Check building(Object value, String call, String name) {
        if ("none".equals(value)) return (s, a) -> (Object)BUILDING.invokeExact(s) == null;
        if ("any".equals(value)) return (s, a) -> (Object)BUILDING.invokeExact(s) != null;
        if (!(value instanceof String key)) throw new IllegalArgumentException(call + ": " + name + " must be \"none\", \"any\" or a building key");
        Buildings buildings = GameApi.buildings();
        if (buildings == null) throw new IllegalArgumentException(call + ": " + name + ": the buildings are not available in this game");
        return new Check() {
            private long seen = -1;
            private Object def;
            // The version the buildings had in the query that ran last (a query changes none): asked once for each query, not for each square.
            private int queryEpoch = -1;
            private long queryVersion;

            @Override public boolean test(Object square, Object anchor) throws Throwable {
                long version;
                if (depth > 0 && queryEpoch == epoch) version = queryVersion;
                else {
                    version = buildings.observe();
                    if (depth > 0) { queryEpoch = epoch; queryVersion = version; }
                }
                if (version != seen) {
                    seen = version;
                    Buildings.Building found = buildings.resolve(key);
                    def = found == null ? null : found.def();
                }
                if (def == null) return false;
                Object own = (Object)BUILDING.invokeExact(square);
                return own != null && (Object)BUILDING_DEF.invokeExact(own) == def;
            }
        };
    }

    private static Check zonesNot(String[] types) {
        // The zones at a square are put into a list this filter keeps (the game's call takes one), cleared before each question.
        var zones = new ArrayList<Object>();
        @SuppressWarnings({ "unchecked", "rawtypes" })
        Check check = (s, a) -> {
            Object grid = metaGrid();
            if (grid == null) return true;
            zones.clear();
            ArrayList list = zones;
            ArrayList<?> at = (ArrayList<?>)ZONES_AT.invokeExact(grid, (int)Reach.SQUARE_X.invokeExact(s), (int)Reach.SQUARE_Y.invokeExact(s),
                (int)Reach.SQUARE_Z.invokeExact(s), list);
            for (int index = 0, size = at.size(); index < size; index++) {
                Object type = (Object)ZONE_TYPE.invokeExact(at.get(index));
                for (String avoided : types) if (avoided.equals(type)) return false;
            }
            return true;
        };
        return check;
    }

    private static Check distance(Kahlua lua, Object value, String call, String name) throws Throwable {
        if (!lua.isTable(value)) throw new IllegalArgumentException(call + ": " + name + " must be { x =, y =, min =, max = }");
        for (Map.Entry<Object, Object> option : lua.entries(value))
            if (!"x".equals(option.getKey()) && !"y".equals(option.getKey()) && !"min".equals(option.getKey()) && !"max".equals(option.getKey()))
                throw new IllegalArgumentException(call + ": " + name + "." + option.getKey() + " is not x, y, min or max");
        double px = number(lua.get(value, "x"), call, name + ".x"), py = number(lua.get(value, "y"), call, name + ".y");
        Object low = lua.get(value, "min"), high = lua.get(value, "max");
        if (low == null && high == null) throw new IllegalArgumentException(call + ": " + name + " needs min or max");
        double minSquared = low == null || number(low, call, name + ".min") <= 0 ? Double.NEGATIVE_INFINITY : Math.pow(number(low, call, name + ".min"), 2);
        double maxSquared = high == null ? Double.POSITIVE_INFINITY : number(high, call, name + ".max") < 0 ? -1 : Math.pow(number(high, call, name + ".max"), 2);
        return (s, a) -> {
            double dx = (int)Reach.SQUARE_X.invokeExact(s) - px, dy = (int)Reach.SQUARE_Y.invokeExact(s) - py;
            double squared = dx * dx + dy * dy;
            return squared >= minSquared && squared <= maxSquared;
        };
    }

    static double number(Object value, String call, String name) {
        if (!(value instanceof Double number) || number.isNaN() || number.isInfinite()) throw new IllegalArgumentException(call + ": " + name + " must be a number");
        return number;
    }

    /** As above, for the value {@code prefix + name + suffix}: that name is made only when the value is wrong. */
    static double number(Object value, String call, String prefix, String name, String suffix) {
        if (value instanceof Double number && !number.isNaN() && !number.isInfinite()) return number;
        return number(value, call, prefix + name + suffix);
    }

    // ---- the conditions that look at other squares ----

    private static final int[][] AROUND = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } };

    private static boolean around(Object square, SquareFilter inner, Object anchor) throws Throwable {
        Object cell = (Object)CELL.invokeExact(square);
        int x = (int)Reach.SQUARE_X.invokeExact(square), y = (int)Reach.SQUARE_Y.invokeExact(square), z = (int)Reach.SQUARE_Z.invokeExact(square);
        for (int[] step : AROUND) if (inner.passesAt(cell, x + step[0], y + step[1], z, anchor)) return true;
        return false;
    }

    private static boolean clear(Object square, int r, SquareFilter inner, Object anchor) throws Throwable {
        Object cell = (Object)CELL.invokeExact(square);
        int x = (int)Reach.SQUARE_X.invokeExact(square), y = (int)Reach.SQUARE_Y.invokeExact(square), z = (int)Reach.SQUARE_Z.invokeExact(square);
        for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++)
                if (!inner.passesAt(cell, x + dx, y + dy, z, anchor)) return false;
        return true;
    }

    // ---- door edges ----

    private static final int NORTH_EDGE = 1, WEST_EDGE = 2;

    /** No door and no doorway on any of the four edges of the square, as {@code doorEdge = false} says (true: one on some edge). */
    private static Check doorEdge(boolean want, String call, String name) {
        Object doorN = flag("DoorWallN", call, name), doorW = flag("DoorWallW", call, name);
        return (s, a) -> {
            // The square's own north and west edges, then the north edge of the square south of it and the west edge of the one east.
            boolean found = (edges(s, doorN, doorW) & (NORTH_EDGE | WEST_EDGE)) != 0;
            if (!found) {
                Object cell = (Object)CELL.invokeExact(s);
                int x = (int)Reach.SQUARE_X.invokeExact(s), y = (int)Reach.SQUARE_Y.invokeExact(s), z = (int)Reach.SQUARE_Z.invokeExact(s);
                Object south = (Object)Reach.GRID_SQUARE.invokeExact(cell, x, y + 1, z);
                if (south != null && (edges(south, doorN, doorW) & NORTH_EDGE) != 0) found = true;
                else {
                    Object east = (Object)Reach.GRID_SQUARE.invokeExact(cell, x + 1, y, z);
                    found = east != null && (edges(east, doorN, doorW) & WEST_EDGE) != 0;
                }
            }
            return found == want;
        };
    }

    /** The edges of a square (its own north and west) that have a door or a doorway: a flag, an IsoDoor, or a door IsoThumpable facing that way. */
    private static int edges(Object square, Object doorN, Object doorW) throws Throwable {
        int mask = 0;
        if ((boolean)HAS_FLAG.invokeExact(square, doorN)) mask |= NORTH_EDGE;
        if ((boolean)HAS_FLAG.invokeExact(square, doorW)) mask |= WEST_EDGE;
        if (mask == (NORTH_EDGE | WEST_EDGE)) return mask;
        List<?> objects = (List<?>)OBJECTS.invokeExact(square);
        for (int at = 0, size = objects.size(); at < size; at++) {
            Object object = objects.get(at);
            if (DOOR.isInstance(object)) mask |= (boolean)DOOR_NORTH.invokeExact(object) ? NORTH_EDGE : WEST_EDGE;
            else if (THUMPABLE.isInstance(object) && (boolean)THUMP_IS_DOOR.invokeExact(object))
                mask |= (boolean)THUMP_NORTH.invokeExact(object) ? NORTH_EDGE : WEST_EDGE;
        }
        return mask;
    }
}
