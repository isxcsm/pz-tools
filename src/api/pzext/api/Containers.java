package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import pzext.api.Buildings.Building;
import pzext.api.Buildings.Rect;

/**
 * {@code PZExtAPI.buildings.containers} and {@code containersNear}: the containers that world objects hold (shelves, counters,
 * fridges, crates, a car's trunk is not one: it belongs to no square), walked in Java over the squares of a building or around a
 * point, with the results flat and compact (docs/design.md, "Containers").
 *
 * <p>A walk asks each loaded square for its objects once, and each object that has containers for them, through handles the
 * compiler builds into the loop. Nothing is allocated for a square without containers. The list is one Lua table of {@link #STRIDE}
 * values a container, so a mod that calls it every minute makes no table for each container, and with {@code into} none at all
 * but the numbers.
 *
 * <p>"Opened" is the game's explored flag unless the call names a mod data key ({@code openedData}): the game sets that flag when it
 * rolls a container's loot, which in single player is when its square first loads, so it tells that the loot was made, not that a
 * player looked. A mod that wants the second marks the objects itself and names its key.
 *
 * <p>"Changed since" is cheap because the game keeps no stamp for a container: a call keeps what it saw (each container's item
 * count and whether it was opened) under a stamp, the last {@link #SNAPSHOTS} stamps, and a call that passes one lists the
 * containers whose count or opened flag differ and those it did not see. A change that leaves the count and the flag as they were
 * (one item swapped for another) is not seen. A container gone (its square unloaded) is not reported.
 */
final class Containers {
    /** The values a container takes in the list. */
    static final int STRIDE = 7;
    /** The most squares one call walks around a point: a bound on the work of one call, not a rule of play. */
    static final int MAX_RADIUS = Buildings.MAX_TILES;
    /** The stamps whose containers are kept for {@code since}, and the most containers kept for one. */
    static final int SNAPSHOTS = 16, SNAPSHOT_MAX = 50_000;
    private static final int MAX_NAMES = 16;
    private static final String AREA = "PZExtAPI.buildings.";
    private static final Pattern NAME = Pattern.compile("[A-Za-z0-9_.-]{1,64}");
    private static final String[] PACKAGES = { "zombie.iso.objects.", "zombie.iso.", "zombie.vehicles." };

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final ClassLoader loader;
    // IsoObject.getContainerCount(), getContainerByIndex(int), hasModData(), getModData(); ItemContainer.getType(), getItems(), isExplored().
    private final MethodHandle count, containerAt, hasData, data, type, items, explored;
    // ArrayList.size(), for the items.
    private final MethodHandle size;
    // The classes a mod named to skip, by name.
    private final Map<String, Class<?>> classes = new java.util.HashMap<>();

    /** What a walk is asked for. */
    private static final class Query {
        String[] types;
        Class<?>[] skipClasses;
        String[] skipData;
        String openedData;
        long since;
        Object into;
    }

    /** The containers a stamp saw, with what to tell them apart by; the stamp's query, so that it is only used for the same one. */
    private record Snapshot(String query, IdentityHashMap<Object, Integer> seen) { }

    // The game thread's: the stamps kept, oldest first, and the last stamp made.
    private final LinkedHashMap<Long, Snapshot> snapshots = new LinkedHashMap<>();
    private long stamp;
    // The world the stamps were made in: another cell takes them away.
    private Object world;

    Containers(Kahlua lua, Game game, Buildings buildings, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        this.loader = loader;
        Class<?> object = game.objectType, container = game.container;
        count = Game.exact(object.getMethod("getContainerCount"), MethodType.methodType(int.class, Object.class));
        containerAt = Game.exact(object.getMethod("getContainerByIndex", int.class), MethodType.methodType(Object.class, Object.class, int.class));
        hasData = Game.exact(object.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        data = Game.exact(object.getMethod("getModData"), MethodType.methodType(Object.class, Object.class));
        type = Game.exact(container.getMethod("getType"), MethodType.methodType(String.class, Object.class));
        items = Game.exact(container.getMethod("getItems"), MethodType.methodType(Object.class, Object.class));
        explored = Game.exact(container.getMethod("isExplored"), MethodType.methodType(boolean.class, Object.class));
        size = Game.exact(ArrayList.class.getMethod("size"), MethodType.methodType(int.class, Object.class));
    }

    /** Sets this area's functions into the buildings' table, replacing those of an earlier API. */
    void register(Object table) throws ReflectiveOperationException {
        String containersCall = AREA + "containers", nearCall = AREA + "containersNear";
        lua.set(table, "containers", lua.function(containersCall, arguments -> containers(
            Arguments.string(arguments, 0, containersCall, "key"), query(arguments.length > 1 ? arguments[1] : null, containersCall))));
        lua.set(table, "containersNear", lua.function(nearCall, arguments -> near(
            Arguments.integer(arguments, 0, nearCall, "x"), Arguments.integer(arguments, 1, nearCall, "y"),
            Arguments.integer(arguments, 2, nearCall, "z", -Zombies.MAX_LEVEL, Zombies.MAX_LEVEL),
            Arguments.integer(arguments, 3, nearCall, "radius", 0, MAX_RADIUS), query(arguments.length > 4 ? arguments[4] : null, nearCall))));
    }

    /**
     * Reads {@code options}: {@code type} (a container type of the game, such as {@code "shelves"}, or a list: only those),
     * {@code skipClasses} (names of the game's object classes, such as {@code "IsoThumpable"}: objects of those are left out),
     * {@code skipData} (a mod data key, or a list: objects whose data has one are left out), {@code openedData} (a mod data key: a
     * container counts as opened when its object's data has it, not by the game's explored flag), {@code since} (a stamp an earlier call
     * returned: only the containers that changed) and {@code into} (a table for the list, used again).
     */
    private Query query(Object options, String call) throws ReflectiveOperationException {
        var query = new Query();
        if (options == null) return query;
        if (!lua.isTable(options)) throw new IllegalArgumentException(call + ": options must be a table");
        query.types = names(options, "type", call, false);
        query.skipData = names(options, "skipData", call, false);
        Object opened = lua.get(options, "openedData");
        if (opened != null) {
            if (!(opened instanceof String key) || key.isEmpty()) throw new IllegalArgumentException(call + ": options.openedData must be a mod data key");
            query.openedData = key;
        }
        String[] named = names(options, "skipClasses", call, true);
        if (named != null) {
            query.skipClasses = new Class<?>[named.length];
            for (int index = 0; index < named.length; index++) query.skipClasses[index] = skipped(named[index], call);
        }
        Object since = lua.get(options, "since");
        if (since != null) {
            if (!(since instanceof Double number) || number != Math.rint(number) || number < 1) throw new IllegalArgumentException(call + ": options.since must be a stamp this call returned");
            query.since = number.longValue();
        }
        Object into = lua.get(options, "into");
        if (into != null) {
            if (!lua.isTable(into)) throw new IllegalArgumentException(call + ": options.into must be a table");
            query.into = into;
        }
        return query;
    }

    /** A name, or a list of names (a type may hold spaces and more; a key and a class name not), or null when the option is left out. */
    private String[] names(Object options, String name, String call, boolean strict) throws ReflectiveOperationException {
        Object value = lua.get(options, name);
        if (value == null) return null;
        var found = new ArrayList<String>();
        if (value instanceof String single) found.add(single);
        else if (lua.isTable(value)) {
            for (Object entry = lua.get(value, 1.0); entry != null; entry = lua.get(value, (double)(found.size() + 1))) {
                if (!(entry instanceof String text)) throw new IllegalArgumentException(call + ": options." + name + " must be a name or a list of names");
                if (found.size() == MAX_NAMES) throw new IllegalArgumentException(call + ": options." + name + " may have at most " + MAX_NAMES + " names");
                found.add(text);
            }
        } else throw new IllegalArgumentException(call + ": options." + name + " must be a name or a list of names");
        if (found.isEmpty()) throw new IllegalArgumentException(call + ": options." + name + " must name at least one");
        if (strict) for (String text : found) if (!NAME.matcher(text).matches()) throw new IllegalArgumentException(call + ": options." + name + " \"" + text + "\" is not a class name");
        return found.toArray(new String[0]);
    }

    /** The game's object class a name stands for. */
    private Class<?> skipped(String name, String call) {
        Class<?> found = classes.get(name);
        if (found != null) return found;
        for (String prefix : PACKAGES) {
            try { found = Game.type(loader, prefix + name); }
            catch (ClassNotFoundException other) { continue; }
            if (game.objectType.isAssignableFrom(found)) break;
            found = null;
        }
        if (found == null) throw new IllegalArgumentException(call + ": options.skipClasses \"" + name + "\" is not one of the game's object classes (such as \"IsoThumpable\")");
        classes.put(name, found);
        return found;
    }

    // ---- the walks ----

    /** What one walk collects. */
    private final class Walk {
        final Query query;
        final String queryKey;
        final Snapshot before;
        final IdentityHashMap<Object, Integer> seen = new IdentityHashMap<>();
        final List<Object> found = new ArrayList<>();
        final Object cells;
        boolean complete = true;
        int total, opened, listed;

        Walk(Query query, String queryKey) throws ReflectiveOperationException {
            this.query = query;
            this.queryKey = queryKey;
            Snapshot kept = query.since > 0 ? snapshots.get(query.since) : null;
            before = kept != null && kept.query().equals(queryKey) ? kept : null;
            cells = game.cell();
        }

        /** The containers of the objects on the square at (x, y, z), each once. */
        void square(int x, int y, int z) throws Throwable {
            Object loaded = game.square(cells, x, y, z);
            if (loaded == null) { complete = false; return; }
            List<?> objects = game.objectList(loaded);
            for (int index = 0, objectCount = objects.size(); index < objectCount; index++) {
                Object object = objects.get(index);
                int held = (int)count.invokeExact(object);
                if (held == 0 || skips(query, object)) continue;
                boolean marked = query.openedData != null && (boolean)hasData.invokeExact(object)
                    && lua.get((Object)data.invokeExact(object), query.openedData) != null;
                for (int at = 0; at < held; at++) {
                    Object container = (Object)containerAt.invokeExact(object, at);
                    if (container == null || seen.containsKey(container)) continue;
                    String kind = (String)type.invokeExact(container);
                    if (query.types != null && !has(query.types, kind)) continue;
                    Object list = (Object)items.invokeExact(container);
                    int amount = (int)size.invokeExact(list);
                    boolean opened = query.openedData != null ? marked : (boolean)explored.invokeExact(container);
                    int signature = amount << 1 | (opened ? 1 : 0);
                    seen.put(container, signature);
                    total++;
                    if (opened) this.opened++;
                    if (before != null) {
                        Integer then = before.seen().get(container);
                        if (then != null && then == signature) continue;
                    }
                    found.add(container); found.add((double)x); found.add((double)y); found.add((double)z);
                    found.add(kind); found.add((double)amount); found.add(opened);
                    listed++;
                }
            }
        }
    }

    private static boolean has(String[] names, String name) {
        if (name != null) for (String wanted : names) if (wanted.equals(name)) return true;
        return false;
    }

    /** Whether the object is one the query leaves out: of a skipped class, or with a skipped key in its data. */
    private boolean skips(Query query, Object object) throws Throwable {
        if (query.skipClasses != null) for (Class<?> skipped : query.skipClasses) if (skipped.isInstance(object)) return true;
        if (query.skipData != null && (boolean)hasData.invokeExact(object)) {
            Object table = (Object)data.invokeExact(object);
            for (String key : query.skipData) if (lua.get(table, key) != null) return true;
        }
        return false;
    }

    /**
     * {@code buildings.containers(key, options)}: {@code list, complete, stamp, total, opened}. The list is {@link #STRIDE} values a
     * container, in a flat table: the game's container, the square's x, y and z, the container's type, how many items it holds and
     * whether it was opened (the game's explored flag, or the object's mark with {@code openedData}). {@code complete} is false when some of the building's squares are not loaded; {@code stamp} is for
     * {@code options.since}; {@code total} and {@code opened} count the containers that match, changed or not. {@code nil, false}
     * for a key that names no building.
     */
    private Object[] containers(String key, Query query) throws Exception {
        Building building = buildings.resolve(key);
        if (building == null) return new Object[] { null, false };
        try {
            var walk = new Walk(query, "b:" + key + options(query));
            for (Object room : building.rooms()) {
                int z = buildings.level(room);
                for (Rect rect : buildings.rects(room))
                    for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                        for (int x = rect.x(); x < rect.x() + rect.w(); x++) walk.square(x, y, z);
            }
            return finish(walk);
        } catch (Exception | Error failure) {
            throw failure;
        } catch (Throwable failure) {
            throw Game.failed(Game.thrown(failure));
        }
    }

    /**
     * {@code buildings.containersNear(x, y, z, radius, options)}: the same for the squares within {@code radius} (0 to 32) of the
     * square, in a box, on its level.
     */
    private Object[] near(int x, int y, int z, int radius, Query query) throws Exception {
        try {
            var walk = new Walk(query, "n:" + x + "," + y + "," + z + "," + radius + options(query));
            for (int wy = y - radius; wy <= y + radius; wy++)
                for (int wx = x - radius; wx <= x + radius; wx++) walk.square(wx, wy, z);
            return finish(walk);
        } catch (Exception | Error failure) {
            throw failure;
        } catch (Throwable failure) {
            throw Game.failed(Game.thrown(failure));
        }
    }

    /** What makes two calls ask the same question: the filters, but not {@code since} or {@code into}. */
    private static String options(Query query) {
        return "|" + Arrays.toString(query.types) + "|" + Arrays.toString(query.skipClasses) + "|" + Arrays.toString(query.skipData)
            + "|" + query.openedData;
    }

    /** Keeps what the walk saw under a stamp, and puts its list in a table. */
    private Object[] finish(Walk walk) throws ReflectiveOperationException {
        Object cell = walk.cells;
        if (cell != world) { snapshots.clear(); world = cell; }
        long made = ++stamp;
        if (walk.seen.size() <= SNAPSHOT_MAX) {
            snapshots.put(made, new Snapshot(walk.queryKey, walk.seen));
            while (snapshots.size() > SNAPSHOTS) snapshots.remove(snapshots.keySet().iterator().next());
        }
        Object list = walk.query.into != null ? walk.query.into : lua.table();
        List<Object> values = walk.found;
        for (int index = 0; index < values.size(); index++) lua.set(list, (double)(index + 1), values.get(index));
        // Taken away: what an earlier call left in a table that is used again.
        for (int index = values.size() + 1; walk.query.into != null && lua.get(list, (double)index) != null; index++) lua.set(list, (double)index, null);
        return new Object[] { list, walk.complete, (double)made, (double)walk.total, (double)walk.opened };
    }
}
