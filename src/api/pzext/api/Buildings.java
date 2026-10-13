package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLongArray;
import pzext.api.Network.Position;

/**
 * {@code PZExtAPI.buildings}: buildings as the game's map data (the meta grid) describes them now, and the objects in
 * and around them that use power or water (docs/design.md, "Buildings"). Facts only; what a mod makes of
 * them is its own.
 */
final class Buildings {
    /** The widest ring {@code near} reads: a bound on the work of one call, not a rule of play. */
    static final int MAX_TILES = 32;
    /**
     * The most squares {@code attached} takes in around one building, built-on rooms and what it looked at beyond them
     * together: past it, a space is no room anyone built, and none are reported.
     */
    static final int ATTACHED_MAX = 1500;
    private static final String AREA = "PZExtAPI.buildings.";
    private static final MethodType GET = MethodType.methodType(Object.class, Object.class);
    private static final MethodType INT = MethodType.methodType(int.class, Object.class);

    private final Kahlua lua;
    private final Game game;
    private final Method roomById;
    private final Method roomName, roomId, userDefined;
    private final Method objectSprite, spriteName, spriteNameOf, properties, has, couldBePowered, consumption;
    // What can be a network's producer (producers): a generator, or an object with a fluid container that holds some.
    private final Class<?> generatorType;
    private final Method fluidContainer, fluidCapacity;
    // The questions describe, rects and roomAt ask many times a call, as handles: no argument array, no boxing, no
    // access check per call (Method.invoke's cost was most of a building's description).
    private final MethodHandle roomAt, building, rooms, roomLevel, roomRects, rectX, rectY, rectW, rectH;
    private final MethodHandle worldNow, gridOf;
    // The game's region data (IsoRegions): what squares no room has are enclosed and roofed, for attached. Null when
    // this game's cannot be read (regionsMissing says why): attached then finds no built-on rooms (nil), and nothing is
    // kept from one call to the next (see version).
    private final MethodHandle regionRoot, regionAt, enclosed, roofed, neighbours;
    private final Class<?> regionType;
    private final String regionsMissing;
    private final Object waterPiped;
    private final Object[] attached;
    private static final int[][] ACROSS = { { 0, -1, 0 }, { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 } };
    // The building's shell: the steps a square of no room takes to the room it counts as in (see shellStep), in order:
    // the square under it (a roof, a balcony on a lower roof), then the squares around it on its level, the sides
    // first (north, east, south, west), then the corners. The order is BU's (Links.homeRoom).
    private static final int[][] SHELL = { { 0, 0, -1 }, { 0, -1, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 },
        { 1, -1, 0 }, { 1, 1, 0 }, { -1, 1, 0 }, { -1, -1, 0 } };
    // Each square's shell step, worked out once for the version of the buildings: a slot of a fixed table holds the
    // square and its step (an index into SHELL plus two; one for none), read and written whole, so that no hook sees
    // half of one and none allocates.
    private static final int SHELL_SLOTS = 1 << 14;
    private final AtomicLongArray shell = new AtomicLongArray(SHELL_SLOTS);
    private volatile long shellVersion = -1;
    private static final int[][] SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
    private static final int[] NONE = {};

    /**
     * What a sprite says of the objects that have it: the wall it hangs on, as the step to the square across ({ dx, dy },
     * or none), and whether the game can pipe water to it. Sprites are few and shared, and the hooks ask often.
     */
    private record Facts(int[] across, boolean piped) { }
    private final Map<Object, Facts> facts = new ConcurrentHashMap<>();

    // What changes buildings, and the region data attached reads: the game swaps in the region data its worker thread
    // worked out (IsoRegions.update, on the game's thread, once a frame at most), and as it does makes, changes and
    // drops the buildings players build (DataRoot.clientProcessBuildings); a map building is made as its world loads
    // and is the same until it is left. So while the world, its meta grid and its region data are the same objects,
    // every building is as described, and kept here: version counts the changes. Watched each frame (observe) and as
    // each call that reads buildings starts, so a swap is never missed between two looks: one frame holds one swap.
    private static final Object UNSEEN = new Object();
    private Object seenGrid = UNSEEN, seenRoot = UNSEEN;
    private long version;
    private static final Building NO_ROOMS = new Building(null, List.of(), "", 0, 0, 0, 0, 0, 0);
    private final Map<Object, Building> described = new IdentityHashMap<>();
    private final Map<Object, List<Space>> spaces = new IdentityHashMap<>();
    // Its own list, told apart by identity: List.of() is the one every empty list of spaces is.
    private static final List<Space> TOO_LARGE = Collections.unmodifiableList(new ArrayList<>());

    Buildings(Kahlua lua, Game game, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        Class<?> world = Game.type(loader, "zombie.iso.IsoWorld"), grid = Game.type(loader, "zombie.iso.IsoMetaGrid");
        Class<?> room = Game.type(loader, "zombie.iso.RoomDef"), rect = Game.type(loader, "zombie.iso.RoomDef$RoomRect");
        Class<?> def = Game.type(loader, "zombie.iso.BuildingDef"), object = game.objectType;
        Class<?> sprite = Game.type(loader, "zombie.iso.sprite.IsoSprite");
        Class<?> container = Game.type(loader, "zombie.core.properties.PropertyContainer");
        Class<?> flag = Game.type(loader, "zombie.iso.SpriteDetails.IsoFlagType");
        roomAt = Game.exact(grid.getMethod("getRoomAt", int.class, int.class, int.class),
            MethodType.methodType(Object.class, Object.class, int.class, int.class, int.class));
        roomById = grid.getMethod("getRoomDefByID", long.class);
        building = Game.exact(room.getMethod("getBuilding"), GET);
        roomName = room.getMethod("getName");
        roomLevel = Game.exact(room.getMethod("getZ"), INT);
        roomRects = Game.exact(room.getMethod("getRects"), GET);
        roomId = room.getMethod("getID");
        rooms = Game.exact(def.getMethod("getRooms"), GET);
        userDefined = def.getMethod("isUserDefined");
        rectX = Game.exact(rect.getMethod("getX"), INT); rectY = Game.exact(rect.getMethod("getY"), INT);
        rectW = Game.exact(rect.getMethod("getW"), INT); rectH = Game.exact(rect.getMethod("getH"), INT);
        worldNow = MethodHandles.publicLookup().unreflectGetter(world.getField("instance")).asType(MethodType.methodType(Object.class));
        gridOf = Game.exact(world.getMethod("getMetaGrid"), GET);
        objectSprite = object.getMethod("getSprite");
        spriteName = object.getMethod("getSpriteName");
        spriteNameOf = sprite.getMethod("getName");
        properties = sprite.getMethod("getProperties");
        has = container.getMethod("has", flag);
        couldBePowered = object.getMethod("couldBePoweredByGenerator");
        consumption = object.getMethod("getGeneratorPowerConsumption");
        waterPiped = flag.getField("waterPiped").get(null);
        generatorType = Game.type(loader, "zombie.iso.objects.IsoGenerator");
        fluidContainer = object.getMethod("getFluidContainer");
        fluidCapacity = Game.type(loader, "zombie.entity.components.fluids.FluidContainer").getMethod("getCapacity");
        attached = new Object[] { flag.getField("attachedN").get(null), flag.getField("attachedS").get(null),
            flag.getField("attachedE").get(null), flag.getField("attachedW").get(null) };
        MethodHandle root = null, at = null, isEnclosed = null, roofs = null, joined = null;
        Class<?> region = null;
        String missing = null;
        try {
            Class<?> regions = Game.type(loader, "zombie.iso.areas.isoregion.IsoRegions");
            region = Game.type(loader, "zombie.iso.areas.isoregion.regions.IsoWorldRegion");
            Field data = Game.accessible(regions.getDeclaredField("dataRoot"));
            root = MethodHandles.lookup().unreflectGetter(data).asType(MethodType.methodType(Object.class));
            at = Game.exact(regions.getMethod("getIsoWorldRegion", int.class, int.class, int.class),
                MethodType.methodType(Object.class, int.class, int.class, int.class));
            isEnclosed = Game.exact(region.getMethod("isEnclosed"), MethodType.methodType(boolean.class, Object.class));
            roofs = Game.exact(region.getMethod("getRoofedPercentage"), MethodType.methodType(float.class, Object.class));
            joined = Game.exact(region.getMethod("getDebugConnectedNeighborCopy"), GET);
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            root = at = isEnclosed = roofs = joined = null;
            region = null;
            missing = unreadable.toString();
        }
        regionRoot = root; regionAt = at; enclosed = isEnclosed; roofed = roofs; neighbours = joined; regionType = region;
        regionsMissing = missing;
    }

    /** Sets this area's functions into its table, replacing those of an earlier API. */
    void register(Object table) throws ReflectiveOperationException {
        lua.set(table, "at", lua.function(AREA + "at", arguments -> new Object[] {
            at(Arguments.integer(arguments, 0, AREA + "at", "x"), Arguments.integer(arguments, 1, AREA + "at", "y"),
                Arguments.integer(arguments, 2, AREA + "at", "z")) }));
        lua.set(table, "rooms", lua.function(AREA + "rooms", arguments -> new Object[] {
            rooms(Arguments.string(arguments, 0, AREA + "rooms", "key")) }));
        lua.set(table, "objects", lua.function(AREA + "objects", arguments -> objects(
            Arguments.string(arguments, 0, AREA + "objects", "key"), Filter.of(arguments, 1, AREA + "objects"))));
        lua.set(table, "near", lua.function(AREA + "near", arguments -> near(
            Arguments.string(arguments, 0, AREA + "near", "key"),
            Arguments.integer(arguments, 1, AREA + "near", "tiles", 0, MAX_TILES), Filter.of(arguments, 2, AREA + "near"))));
        lua.set(table, "version", lua.function(AREA + "version", arguments -> new Object[] { (double)observe() }));
        lua.set(table, "attached", lua.function(AREA + "attached", arguments -> new Object[] {
            attachedTable(Arguments.string(arguments, 0, AREA + "attached", "key")) }));
        lua.set(table, "producers", lua.function(AREA + "producers", arguments -> producers(
            Arguments.string(arguments, 0, AREA + "producers", "key"),
            Arguments.integer(arguments, 1, AREA + "producers", "tiles", 0, MAX_TILES), Filter.of(arguments, 2, AREA + "producers"))));
        lua.set(table, "attachedObjects", lua.function(AREA + "attachedObjects", arguments -> attachedObjects(
            Arguments.string(arguments, 0, AREA + "attachedObjects", "key"), Filter.of(arguments, 1, AREA + "attachedObjects"))));
        lua.set(table, "name", lua.function(AREA + "name", arguments -> {
            Object object = arguments.length > 0 ? arguments[0] : null;
            if (!game.objectType.isInstance(object)) throw new IllegalArgumentException(AREA + "name: object must be a world object");
            return new Object[] { sprite(object) };
        }));
    }

    /** Which objects a call reports: those that use power, water, or either. */
    record Filter(boolean power, boolean water) {
        static Filter of(Object[] arguments, int index, String call) {
            Object value = index < arguments.length ? arguments[index] : null;
            if (value == null) return new Filter(true, true);
            if ("power".equals(value)) return new Filter(true, false);
            if ("water".equals(value)) return new Filter(false, true);
            throw new IllegalArgumentException(call + ": filter must be nil, \"power\" or \"water\"");
        }
    }

    /** A building as its rooms describe it. Its key is its lowest level's northernmost, then westernmost room corner. */
    record Building(Object def, List<Object> rooms, String key, int minLevel, int maxLevel,
            int minX, int minY, int maxX, int maxY) { }
    record Rect(int x, int y, int w, int h) { }

    /**
     * A room a player built onto a building, which the game leaves out of it (see attached): its level, the room of the
     * building it touches most (host), how many squares it has, the larger side of its box, and its squares as rectangles.
     */
    record Space(int level, Object host, int count, int extent, List<Rect> rects) { }

    /** An object that uses power or water, on a loaded square; {@code room} is the room it belongs to, if any. */
    record Found(Object object, int x, int y, int z, Object room, boolean power, boolean water) { }

    /**
     * The number of the buildings and region data as they are now: the same while nothing about any building, nor the
     * region data, can have changed (see above), so that a mod may keep what it read of them until it differs. Without
     * the game's region data, nothing is known to stay: a new number each time.
     */
    synchronized long observe() throws ReflectiveOperationException {
        Object grid, root;
        try {
            Object world = (Object)worldNow.invokeExact();
            grid = world == null ? null : (Object)gridOf.invokeExact(world);
            root = regionRoot == null ? null : (Object)regionRoot.invokeExact();
        } catch (Throwable failure) { throw Game.thrown(failure); }
        if (regionRoot == null || grid != seenGrid || root != seenRoot) {
            seenGrid = grid;
            seenRoot = root;
            version++;
            described.clear();
            spaces.clear();
        }
        return version;
    }

    private Object at(int x, int y, int z) throws ReflectiveOperationException {
        observe();
        Object room = roomAt(x, y, z);
        Building found = room == null ? null : describe(defOf(room));
        if (found == null) return null;
        Object result = lua.table();
        lua.set(result, "key", found.key());
        lua.set(result, "playerBuilt", userDefined.invoke(found.def()));
        lua.set(result, "minLevel", (double)found.minLevel());
        lua.set(result, "maxLevel", (double)found.maxLevel());
        lua.set(result, "minX", (double)found.minX());
        lua.set(result, "minY", (double)found.minY());
        lua.set(result, "maxX", (double)found.maxX());
        lua.set(result, "maxY", (double)found.maxY());
        lua.set(result, "room", roomName.invoke(room));
        lua.set(result, "roomId", Long.toString((long)roomId.invoke(room)));
        return result;
    }

    private Object rooms(String key) throws ReflectiveOperationException {
        Building found = resolve(key);
        if (found == null) return null;
        var result = new ArrayList<Object>();
        for (Object room : found.rooms()) {
            Object entry = lua.table();
            lua.set(entry, "id", Long.toString((long)roomId.invoke(room)));
            lua.set(entry, "name", roomName.invoke(room));
            lua.set(entry, "level", (double)level(room));
            var rects = new ArrayList<Object>();
            for (Rect rect : rects(room)) rects.add(rectTable(rect));
            lua.set(entry, "rects", lua.list(rects));
            result.add(entry);
        }
        return lua.list(result);
    }

    private Object rectTable(Rect rect) throws ReflectiveOperationException {
        Object value = lua.table();
        lua.set(value, "x", (double)rect.x()); lua.set(value, "y", (double)rect.y());
        lua.set(value, "w", (double)rect.w()); lua.set(value, "h", (double)rect.h());
        return value;
    }

    /**
     * The objects of the building's rooms. A light switch belongs to the room it lights ({@code IsoLightSwitch.roomId}),
     * which can be outside its own square's room: one on a south or east wall stands on the square beyond it. The second
     * result is false when some of the building's squares are not loaded, whose objects are then missing.
     */
    private Object[] objects(String key, Filter filter) throws ReflectiveOperationException {
        Building found = resolve(key);
        if (found == null) return new Object[] { null, false };
        boolean[] complete = { true };
        var result = new ArrayList<Object>();
        for (Found thing : scan(found, filter, complete)) result.add(entry(thing));
        return new Object[] { lua.list(result), complete[0] };
    }

    /**
     * The objects of a building's rooms, as {@code objects} reports them: of all its rooms, or of those it was narrowed
     * to (see Members.resolve). {@code complete[0]} is cleared when some were missing.
     */
    List<Found> scan(Building found, Filter filter, boolean[] complete) throws ReflectiveOperationException {
        Object cells = game.cell(), grid = game.metaGrid();
        var result = new ArrayList<Found>();
        var rooms = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        rooms.addAll(found.rooms());
        // A level above the top: what stands on its roof is the building's (see shellStep).
        for (int z = found.minLevel(); z <= found.maxLevel() + 1; z++)
            for (int y = found.minY() - 1; y <= found.maxY() + 1; y++)
                for (int x = found.minX() - 1; x <= found.maxX() + 1; x++) {
                    Object room = roomAt(grid, x, y, z);
                    boolean inside = room != null && rooms.contains(room);
                    Object loaded = game.square(cells, x, y, z);
                    if (loaded == null) { if (inside) complete[0] = false; continue; }
                    for (Object object : game.objectsOn(loaded)) {
                        Object owner = owner(grid, object, room, x, y, z);
                        if (owner == null || !rooms.contains(owner)) continue;
                        Found thing = classify(object, filter, x, y, z, owner);
                        if (thing != null) result.add(thing);
                    }
                }
        return result;
    }

    /**
     * The objects on squares within {@code tiles} of the building (on its own levels, counting diagonal steps as one)
     * that belong to no building. Light switches that light a room are left out: they belong to that room's building.
     */
    private Object[] near(String key, int tiles, Filter filter) throws ReflectiveOperationException {
        Building found = resolve(key);
        if (found == null) return new Object[] { null, false };
        Object grid = game.metaGrid();
        var result = new ArrayList<Object>();
        boolean complete = around(found, tiles, false, (loaded, x, y, z) -> {
            for (Object object : game.objectsOn(loaded)) {
                if (owner(grid, object, null, x, y, z) != null) continue;
                Found thing = classify(object, filter, x, y, z, null);
                if (thing != null) result.add(entry(thing));
            }
        });
        return new Object[] { lua.list(result), complete };
    }

    /**
     * What can be a network's producer in the building's rooms and on squares of no building within {@code tiles} of it
     * (on its own levels, a diagonal step counting as one): generators (power), and objects with a fluid container
     * that holds some (water), whichever network they belong to now. The second result is false when some of those
     * squares were not loaded.
     */
    private Object[] producers(String key, int tiles, Filter filter) throws ReflectiveOperationException {
        Building found = resolve(key);
        if (found == null) return new Object[] { null, false };
        var result = new ArrayList<Object>();
        boolean complete = around(found, tiles, true, (loaded, x, y, z) -> {
            for (Object object : game.objectsOn(loaded)) {
                String utility = producerUtility(object, filter);
                if (utility == null) continue;
                Object entry = lua.table();
                lua.set(entry, "x", (double)x); lua.set(entry, "y", (double)y); lua.set(entry, "z", (double)z);
                lua.set(entry, "sprite", sprite(object));
                lua.set(entry, "type", object.getClass().getSimpleName());
                lua.set(entry, "utility", utility);
                result.add(entry);
            }
        });
        return new Object[] { lua.list(result), complete };
    }

    /** "power" for a generator, "water" for an object with a fluid container that holds some, as the filter lets. */
    private String producerUtility(Object object, Filter filter) throws ReflectiveOperationException {
        if (generatorType.isInstance(object)) return filter.power() ? "power" : null;
        if (!filter.water()) return null;
        Object container = fluidContainer.invoke(object);
        return container != null && (float)fluidCapacity.invoke(container) > 0 ? "water" : null;
    }

    /** A loaded square {@code around} goes over. */
    @FunctionalInterface
    interface SquareVisit { void at(Object square, int x, int y, int z) throws ReflectiveOperationException; }

    /**
     * Goes over the loaded squares of no building within {@code tiles} of the building's rooms, level by level, and
     * with {@code rooms} its rooms' squares too. False when some were not loaded.
     */
    private boolean around(Building found, int tiles, boolean rooms, SquareVisit visit) throws ReflectiveOperationException {
        Object cells = game.cell(), grid = game.metaGrid();
        int left = found.minX() - tiles, top = found.minY() - tiles;
        int width = found.maxX() - found.minX() + 1 + 2 * tiles, height = found.maxY() - found.minY() + 1 + 2 * tiles;
        boolean complete = true;
        for (int z = found.minLevel(); z <= found.maxLevel(); z++) {
            boolean[] inside = new boolean[width * height];
            boolean any = false;
            for (Object room : found.rooms()) {
                if (level(room) != z) continue;
                for (Rect rect : rects(room))
                    for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                        for (int x = rect.x(); x < rect.x() + rect.w(); x++) { inside[(y - top) * width + x - left] = true; any = true; }
            }
            if (!any) continue;
            boolean[] ring = dilate(inside, width, height, tiles);
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++) {
                    boolean own = inside[y * width + x];
                    if (!ring[y * width + x] || own && !rooms) continue;
                    int wx = left + x, wy = top + y;
                    if (!own && roomAt(grid, wx, wy, z) != null) continue;
                    Object loaded = game.square(cells, wx, wy, z);
                    if (loaded == null) { complete = false; continue; }
                    visit.at(loaded, wx, wy, z);
                }
        }
        return complete;
    }

    /** Squares within {@code tiles} steps of a marked one, diagonal steps included: one pass per axis. */
    static boolean[] dilate(boolean[] marked, int width, int height, int tiles) {
        boolean[] rows = new boolean[marked.length], result = new boolean[marked.length];
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
                if (marked[y * width + x])
                    for (int dx = Math.max(0, x - tiles); dx <= Math.min(width - 1, x + tiles); dx++) rows[y * width + dx] = true;
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
                if (rows[y * width + x])
                    for (int dy = Math.max(0, y - tiles); dy <= Math.min(height - 1, y + tiles); dy++) result[dy * width + x] = true;
        return result;
    }

    // Rooms built onto a building. In vanilla a room a player builds against a map building belongs to no building:
    // the game drops a player-built building that touches a map one (WorldRegionToMetaGrid), so its squares have no
    // room. attached finds them from the region data: a space is such a room, or rooms joined by doors and windows as
    // the game's regions have them, enclosed and at least half roofed (what the game takes for a room a player built),
    // that shares a side with a room of the building on the same floor, at or above the ground. Kept until the version
    // changes (observe): a player building or taking down a wall changes the region data.

    /**
     * {@code attached(key)}: the rooms built onto the building, as a list of { level, host (the id of the building's
     * room the space touches most), count (squares), extent (the larger side of its box), rects }; empty for a building
     * players built; nil without such a building, without the game's region data, or when a space grows past
     * ATTACHED_MAX squares, which no room has.
     */
    private Object attachedTable(String key) throws ReflectiveOperationException {
        Building found = resolve(key);
        List<Space> list = found == null ? null : attached(found);
        if (list == null) return null;
        var result = new ArrayList<Object>();
        for (Space space : list) {
            Object entry = lua.table();
            lua.set(entry, "level", (double)space.level());
            lua.set(entry, "host", Long.toString((long)roomId.invoke(space.host())));
            lua.set(entry, "count", (double)space.count());
            lua.set(entry, "extent", (double)space.extent());
            var rects = new ArrayList<Object>();
            for (Rect rect : space.rects()) rects.add(rectTable(rect));
            lua.set(entry, "rects", lua.list(rects));
            result.add(entry);
        }
        return lua.list(result);
    }

    /**
     * {@code attachedObjects(key, filter)}: the objects on the squares of the rooms built onto the building (attached)
     * that belong to no building, as {@code near} reports them, each with the room of the building its space counts in
     * (room and roomId: the space's host). The second result is false when some of those squares are not loaded. Nil
     * (and false) when attached is.
     */
    private Object[] attachedObjects(String key, Filter filter) throws ReflectiveOperationException {
        Building found = resolve(key);
        List<Space> list = found == null ? null : attached(found);
        if (list == null) return new Object[] { null, false };
        Object cells = game.cell(), grid = game.metaGrid();
        var result = new ArrayList<Object>();
        boolean complete = true;
        for (Space space : list)
            for (Rect rect : space.rects())
                for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                    for (int x = rect.x(); x < rect.x() + rect.w(); x++) {
                        Object loaded = game.square(cells, x, y, space.level());
                        if (loaded == null) { complete = false; continue; }
                        for (Object object : game.objectsOn(loaded)) {
                            if (owner(grid, object, null, x, y, space.level()) != null) continue;
                            Found thing = classify(object, filter, x, y, space.level(), space.host());
                            if (thing != null) result.add(entry(thing));
                        }
                    }
        return new Object[] { lua.list(result), complete };
    }

    /** The building's built-on rooms (see attachedTable), kept for the version; null when they cannot be found. */
    synchronized List<Space> attached(Building found) throws ReflectiveOperationException {
        if (regionAt == null) return null;
        if ((boolean)userDefined.invoke(found.def())) return List.of();
        List<Space> known = spaces.get(found.def());
        if (known == null) {
            known = new Fill(found).run();
            spaces.put(found.def(), known == null ? TOO_LARGE : known);
        }
        return known == TOO_LARGE ? null : known;
    }

    private static long squareKey(int x, int y, int z) {
        return (z & 0xFFFFL) << 48 | (y & 0xFFFFFFL) << 24 | x & 0xFFFFFFL;
    }

    /** One look around a building for attached: what was seen of the squares and regions, shared by its spaces. */
    private final class Fill {
        private final Building found;
        private final Object grid;
        private final Map<Long, Object> own = new HashMap<>();
        private final Map<Object, Boolean> alike = new IdentityHashMap<>();
        private final Map<Object, Set<Object>> joined = new IdentityHashMap<>();
        private final Set<Long> claimed = new HashSet<>(), outside = new HashSet<>();
        private final List<Space> spaces = new ArrayList<>();
        private int total;

        Fill(Building found) throws ReflectiveOperationException {
            this.found = found;
            this.grid = game.metaGrid();
        }

        /** The spaces around the building's rooms: a list, or null when one grows too large. */
        List<Space> run() throws ReflectiveOperationException {
            var around = new ArrayList<int[]>();
            for (Object room : found.rooms()) {
                int z = level(room);
                if (z < 0) continue;
                for (Rect rect : rects(room)) {
                    around.add(new int[] { rect.x(), rect.y(), rect.w(), rect.h(), z });
                    for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                        for (int x = rect.x(); x < rect.x() + rect.w(); x++) own.put(squareKey(x, y, z), room);
                }
            }
            for (int[] rect : around) {
                int rx = rect[0], ry = rect[1], rw = rect[2], rh = rect[3], z = rect[4];
                for (int x = rx; x < rx + rw; x++) if (!look(x, ry - 1, z) || !look(x, ry + rh, z)) return null;
                for (int y = ry; y < ry + rh; y++) if (!look(rx - 1, y, z) || !look(rx + rw, y, z)) return null;
            }
            return List.copyOf(spaces);
        }

        private Object regionAt(int x, int y, int z) throws ReflectiveOperationException {
            Object region;
            try { region = (Object)regionAt.invokeExact(x, y, z); }
            catch (Throwable failure) { throw Game.thrown(failure); }
            return regionType.isInstance(region) ? region : null;
        }

        /** What the game takes for a room a player built: an enclosed region at least half roofed. */
        private boolean qualifies(Object region) throws ReflectiveOperationException {
            Boolean known = alike.get(region);
            if (known == null) {
                try { known = (boolean)enclosed.invokeExact(region) && (float)roofed.invokeExact(region) >= 0.5f; }
                catch (Throwable failure) { throw Game.thrown(failure); }
                alike.put(region, known);
            }
            return known;
        }

        /** The regions a region is joined to by a door or a window. */
        private Set<Object> joinedTo(Object region) throws ReflectiveOperationException {
            Set<Object> set = joined.get(region);
            if (set == null) {
                set = Collections.newSetFromMap(new IdentityHashMap<>());
                List<?> list;
                try { list = (List<?>)(Object)neighbours.invokeExact(region); }
                catch (Throwable failure) { throw Game.thrown(failure); }
                if (list != null) set.addAll(list);
                joined.put(region, set);
            }
            return set;
        }

        /** A square across a side of a room of the building: false when a space there grew too large. */
        private boolean look(int x, int y, int z) throws ReflectiveOperationException {
            long key = squareKey(x, y, z);
            if (own.containsKey(key) || claimed.contains(key) || outside.contains(key)) return true;
            if (roomAt(grid, x, y, z) != null) { outside.add(key); return true; }
            Object region = regionAt(x, y, z);
            if (region == null || !qualifies(region)) { outside.add(key); return true; }
            Space space = fill(x, y, z, region);
            if (space == null) return false;
            if (space.host() != null) spaces.add(space);
            return true;
        }

        /**
         * The space that begins at a square of a region: the squares of the region and of those joined to it. Null
         * when it grows too large.
         */
        private Space fill(int startX, int startY, int z, Object start) throws ReflectiveOperationException {
            var squares = new HashSet<Long>();
            squares.add(squareKey(startX, startY, z));
            claimed.add(squareKey(startX, startY, z));
            var touches = new IdentityHashMap<Object, Integer>();
            var regions = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
            regions.add(start);
            var qx = new ArrayList<Integer>(List.of(startX));
            var qy = new ArrayList<Integer>(List.of(startY));
            var qr = new ArrayList<Object>(List.of(start));
            total++;
            for (int head = 0; head < qx.size(); head++) {
                int cx = qx.get(head), cy = qy.get(head);
                Object current = qr.get(head);
                for (int[] side : SIDES) {
                    int nx = cx + side[0], ny = cy + side[1];
                    long key = squareKey(nx, ny, z);
                    Object room = own.get(key);
                    if (room != null) {
                        touches.merge(room, 1, Integer::sum);
                    } else if (!claimed.contains(key) && !outside.contains(key) && roomAt(grid, nx, ny, z) == null) {
                        Object other = regionAt(nx, ny, z);
                        boolean join = other != null && (regions.contains(other)
                            || qualifies(other) && (other == current || joinedTo(current).contains(other)));
                        if (join) {
                            regions.add(other);
                            squares.add(key);
                            claimed.add(key);
                            total++;
                            if (total > ATTACHED_MAX) return null;
                            qx.add(nx); qy.add(ny); qr.add(other);
                        } else if (other == null || !qualifies(other)) {
                            outside.add(key);
                        }
                    }
                }
            }
            Object host = null;
            int best = 0;
            for (Object room : found.rooms()) {
                int count = touches.getOrDefault(room, 0);
                if (count > best) { host = room; best = count; }
            }
            List<Rect> rects = squareRects(qx, qy);
            int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE, maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE;
            for (Rect rect : rects) {
                minX = Math.min(minX, rect.x()); minY = Math.min(minY, rect.y());
                maxX = Math.max(maxX, rect.x() + rect.w() - 1); maxY = Math.max(maxY, rect.y() + rect.h() - 1);
            }
            int extent = Math.max(maxX - minX, maxY - minY) + 1;
            return new Space(z, host, squares.size(), extent, rects);
        }
    }

    /** Squares of one floor as rectangles: runs along x, joined down where the next row has the same run. */
    static List<Rect> squareRects(List<Integer> xs, List<Integer> ys) {
        var rows = new TreeMap<Integer, List<Integer>>();
        for (int index = 0; index < xs.size(); index++) rows.computeIfAbsent(ys.get(index), row -> new ArrayList<>()).add(xs.get(index));
        // A rectangle grows down while the rows under it have its run: { x, y, w, h }.
        var result = new ArrayList<int[]>();
        Map<Long, int[]> open = Map.of();
        for (var row : rows.entrySet()) {
            int y = row.getKey();
            List<Integer> run = row.getValue();
            Collections.sort(run);
            var runs = new HashMap<Long, int[]>();
            int start = run.get(0), last = start;
            for (int index = 1; index <= run.size(); index++) {
                Integer x = index < run.size() ? run.get(index) : null;
                if (x == null || x != last + 1) {
                    long key = (long)start << 32 | (last - start + 1) & 0xFFFFFFFFL;
                    int[] rect = open.get(key);
                    if (rect != null && rect[1] + rect[3] == y) rect[3]++;
                    else { rect = new int[] { start, y, last - start + 1, 1 }; result.add(rect); }
                    runs.put(key, rect);
                    if (x != null) start = x;
                }
                if (x != null) last = x;
            }
            open = runs;
        }
        var rects = new ArrayList<Rect>(result.size());
        for (int[] rect : result) rects.add(new Rect(rect[0], rect[1], rect[2], rect[3]));
        return rects;
    }

    /**
     * The room an object belongs to: a light switch's lit room, or else its square's room, or else, for one hanging on a
     * wall outside (a lamp on a building's outer wall), the room across that wall (see {@link #home}).
     */
    private Object owner(Object grid, Object object, Object squareRoom, int x, int y, int z) throws ReflectiveOperationException {
        if (game.lightSwitch.isInstance(object)) {
            long lit = game.switchRoom(object);
            Object room = lit == -1 || grid == null ? null : roomById.invoke(grid, lit);
            if (room != null) return room;
        }
        if (squareRoom != null || grid == null) return squareRoom;
        int[] step = stepOut(grid, object, x, y, z);
        return step == null ? null : roomAt(grid, x + step[0], y + step[1], z + step[2]);
    }

    /**
     * The square an object counts as standing in: its own, or, for one on a square of no room, a square of the room it
     * belongs to: the square across the wall it hangs on (its sprite is attached north, south, east or west) when a room
     * is there, else the building's shell (see {@link #shellStep}): a roof's room under it, or the room beside it. A
     * lamp on a building's outer wall, a barrel on its roof and a sprinkler against its wall are the building's.
     */
    Position home(Object object, Position at) throws ReflectiveOperationException {
        if (at == null) return null;
        int[] step = homeStep(object, at.x(), at.y(), at.z());
        return step == null ? at : new Position(at.x() + step[0], at.y() + step[1], at.z() + step[2]);
    }

    /**
     * {@link #home} without allocating: the step { dx, dy, dz } to the square of the room the object belongs to; null
     * for its own square, and for one that belongs to no building. One in a room costs a look at the map; one outside,
     * the shell's steps, worked out once a square.
     */
    int[] homeStep(Object object, int x, int y, int z) throws ReflectiveOperationException {
        Object grid = grid();
        if (grid == null || roomAt(grid, x, y, z) != null) return null;
        return stepOut(grid, object, x, y, z);
    }

    /** For an object on a square of no room: the step across the wall it hangs on to a room, or the shell's; or null. */
    private int[] stepOut(Object grid, Object object, int x, int y, int z) throws ReflectiveOperationException {
        int[] across = across(object);
        if (across.length != 0 && roomAt(grid, x + across[0], y + across[1], z) != null) return across;
        return shellStep(grid, x, y, z);
    }

    /**
     * The step from a square of no room to the room it counts as in, as the building's shell: the room under it, else
     * the first room around it on its level (see {@link #SHELL}); null for none. The caller knows the square has no room.
     * Kept a square for the version of the buildings.
     */
    int[] shellStep(Object grid, int x, int y, int z) throws ReflectiveOperationException {
        long now = version;
        if (shellVersion != now) {
            for (int slot = 0; slot < SHELL_SLOTS; slot++) shell.set(slot, 0);
            shellVersion = now;
        }
        long key = (long)(x & 0x3FFFFF) << 30 | (long)(y & 0x3FFFFF) << 8 | (z + 64) & 0xFF;
        int slot = (int)(key * 0x9E3779B97F4A7C15L >>> 50) & SHELL_SLOTS - 1;
        long entry = shell.get(slot);
        int code;
        if (entry >>> 8 == key && entry != 0) code = (int)(entry & 0xFF);
        else {
            code = 1;
            for (int index = 0; index < SHELL.length; index++) {
                int[] step = SHELL[index];
                if (roomAt(grid, x + step[0], y + step[1], z + step[2]) != null) { code = index + 2; break; }
            }
            shell.set(slot, key << 8 | code);
        }
        return code == 1 ? null : SHELL[code - 2];
    }

    /** The room a square of no room counts as in, as the building's shell (see {@link #shellStep}); null for none. */
    Object shellRoom(int x, int y, int z) throws ReflectiveOperationException {
        Object grid = grid();
        if (grid == null || roomAt(grid, x, y, z) != null) return null;
        int[] step = shellStep(grid, x, y, z);
        return step == null ? null : roomAt(grid, x + step[0], y + step[1], z + step[2]);
    }

    /** The world's meta grid, or null, without allocating (the hooks' path). */
    private Object grid() throws ReflectiveOperationException {
        try {
            Object world = (Object)worldNow.invokeExact();
            return world == null ? null : (Object)gridOf.invokeExact(world);
        } catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The step to the square across the wall the object's sprite hangs on, or none. */
    private int[] across(Object object) throws ReflectiveOperationException {
        Facts known = facts(object);
        return known == null ? NONE : known.across();
    }

    private Facts facts(Object object) throws ReflectiveOperationException {
        Object sprite = objectSprite.invoke(object, Game.NONE);
        if (sprite == null) return null;
        Facts known = facts.get(sprite);
        if (known != null) return known;
        Object flags = properties.invoke(sprite);
        int[] step = NONE;
        for (int side = 0; flags != null && side < attached.length; side++)
            if ((boolean)has.invoke(flags, attached[side])) { step = ACROSS[side]; break; }
        known = new Facts(step, flags != null && (boolean)has.invoke(flags, waterPiped));
        facts.put(sprite, known);
        return known;
    }

    /** The object when it uses what the filter asks for, or null. */
    Found classify(Object object, Filter filter, int x, int y, int z, Object room) throws ReflectiveOperationException {
        boolean power = (boolean)couldBePowered.invoke(object), water = piped(object);
        return power && filter.power() || water && filter.water() ? new Found(object, x, y, z, room, power, water) : null;
    }

    /** Whether the game can pipe water to the object: its sprite has the {@code waterPiped} flag. */
    boolean piped(Object object) throws ReflectiveOperationException {
        Facts known = facts(object);
        return known != null && known.piped();
    }

    /** The object as a Lua table, with the consumption the game gives for it now. */
    Object entry(Found thing) throws ReflectiveOperationException {
        Object result = lua.table();
        lua.set(result, "x", (double)thing.x()); lua.set(result, "y", (double)thing.y()); lua.set(result, "z", (double)thing.z());
        lua.set(result, "sprite", sprite(thing.object()));
        lua.set(result, "type", thing.object().getClass().getSimpleName());
        if (thing.room() != null) {
            lua.set(result, "room", roomName.invoke(thing.room()));
            lua.set(result, "roomId", Long.toString((long)roomId.invoke(thing.room())));
        }
        if (thing.power()) lua.set(result, "power", (double)consumption(thing.object()));
        if (thing.water()) lua.set(result, "water", true);
        return result;
    }

    /**
     * The name objects are known by: the object's sprite name, or its sprite's; or the name a mod gives that sprite
     * (machine.spriteName).
     */
    String sprite(Object object) throws ReflectiveOperationException {
        Object name = spriteName.invoke(object);
        if (name == null) {
            Object sprite = objectSprite.invoke(object);
            if (sprite != null) name = spriteNameOf.invoke(sprite);
        }
        Formulas formulas = GameApi.formulas();
        return name == null || formulas == null ? (String)name : formulas.spriteName((String)name);
    }

    /** What the game gives for the object's power use now. */
    float consumption(Object object) throws ReflectiveOperationException { return (float)consumption.invoke(object); }

    /** The building a key names, or null when no building has that key now (it was rebuilt, or removed). */
    Building resolve(String key) throws ReflectiveOperationException {
        String[] parts = key.split(",", -1);
        if (parts.length != 3) return null;
        int x, y, z;
        try { x = Integer.parseInt(parts[0]); y = Integer.parseInt(parts[1]); z = Integer.parseInt(parts[2]); }
        catch (NumberFormatException notAKey) { return null; }
        observe();
        Object room = roomAt(x, y, z);
        Building found = room == null ? null : describe(defOf(room));
        return found != null && found.key().equals(key) ? found : null;
    }

    /** The building the square belongs to now, or null. */
    Building buildingAt(int x, int y, int z) throws ReflectiveOperationException {
        observe();
        Object room = roomAt(x, y, z);
        return room == null ? null : describe(defOf(room));
    }

    /** The room the square belongs to now (a RoomDef), or null. */
    Object roomOf(int x, int y, int z) throws ReflectiveOperationException { return roomAt(x, y, z); }

    /** The building of a room, as its rooms describe it now. */
    Building buildingOf(Object room) throws ReflectiveOperationException {
        observe();
        return describe(defOf(room));
    }

    /** The room's building (a BuildingDef). */
    private Object defOf(Object room) throws ReflectiveOperationException {
        try { return (Object)building.invokeExact(room); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The building narrowed to some of its rooms, in its own order: what a network takes of it. */
    static Building narrowed(Building whole, Set<Object> rooms) {
        var kept = new ArrayList<Object>();
        for (Object room : whole.rooms()) if (rooms.contains(room)) kept.add(room);
        return new Building(whole.def(), List.copyOf(kept), whole.key(), whole.minLevel(), whole.maxLevel(),
            whole.minX(), whole.minY(), whole.maxX(), whole.maxY());
    }

    int level(Object room) throws ReflectiveOperationException {
        try { return (int)roomLevel.invokeExact(room); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    long roomId(Object room) throws ReflectiveOperationException { return (long)roomId.invoke(room); }

    /** The building as its rooms describe it, kept for the version (see observe): the caller observed first. */
    private synchronized Building describe(Object def) throws ReflectiveOperationException {
        if (def == null) return null;
        Building known = described.get(def);
        if (known == null) {
            known = describeNow(def);
            described.put(def, known == null ? NO_ROOMS : known);
        }
        return known == NO_ROOMS ? null : known;
    }

    private Building describeNow(Object def) throws ReflectiveOperationException {
        List<?> own;
        try { own = (List<?>)(Object)rooms.invokeExact(def); }
        catch (Throwable failure) { throw Game.thrown(failure); }
        var list = new ArrayList<Object>(own);
        int minLevel = Integer.MAX_VALUE, maxLevel = Integer.MIN_VALUE;
        int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE, maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE;
        int keyX = 0, keyY = 0;
        for (Object room : list) {
            int level = level(room);
            for (Rect rect : rects(room)) {
                if (level < minLevel || level == minLevel && (rect.y() < keyY || rect.y() == keyY && rect.x() < keyX)) {
                    minLevel = Math.min(minLevel, level); keyX = rect.x(); keyY = rect.y();
                }
                maxLevel = Math.max(maxLevel, level);
                minX = Math.min(minX, rect.x()); minY = Math.min(minY, rect.y());
                maxX = Math.max(maxX, rect.x() + rect.w() - 1); maxY = Math.max(maxY, rect.y() + rect.h() - 1);
            }
        }
        if (minLevel == Integer.MAX_VALUE) return null; // No room has a square.
        return new Building(def, List.copyOf(list), keyX + "," + keyY + "," + minLevel, minLevel, maxLevel, minX, minY, maxX, maxY);
    }

    List<Rect> rects(Object room) throws ReflectiveOperationException {
        var result = new ArrayList<Rect>();
        try {
            for (Object rect : (List<?>)(Object)roomRects.invokeExact(room)) {
                int w = (int)rectW.invokeExact(rect), h = (int)rectH.invokeExact(rect);
                if (w > 0 && h > 0) result.add(new Rect((int)rectX.invokeExact(rect), (int)rectY.invokeExact(rect), w, h));
            }
        } catch (Throwable failure) { throw Game.thrown(failure); }
        return result;
    }

    private Object roomAt(int x, int y, int z) throws ReflectiveOperationException { return roomAt(game.metaGrid(), x, y, z); }

    /** The room at the square, from the meta grid a caller that asks about many squares got once. */
    private Object roomAt(Object grid, int x, int y, int z) throws ReflectiveOperationException {
        if (grid == null) return null;
        try { return (Object)roomAt.invokeExact(grid, x, y, z); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** Why attached finds nothing in this game, or null when it can look. */
    String regionsMissing() { return regionsMissing; }
}
