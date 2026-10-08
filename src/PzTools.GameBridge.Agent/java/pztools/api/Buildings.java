package pztools.api;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import pztools.api.Network.Position;

/**
 * {@code PZToolsAPI.buildings}: buildings as the game's map data (the meta grid) describes them now, and the objects in
 * and around them that use power or water (docs/design/extension-api.md, "Buildings"). Facts only; what a mod makes of
 * them is its own.
 */
final class Buildings {
    /** The widest ring {@code near} reads: a bound on the work of one call, not a rule of play. */
    static final int MAX_TILES = 32;
    private static final String AREA = "PZToolsAPI.buildings.";

    private final Kahlua lua;
    private final Game game;
    private final Method roomAt, roomById;
    private final Method building, roomName, roomLevel, roomRects, roomId, rooms, userDefined;
    private final Method rectX, rectY, rectW, rectH;
    private final Method objectSprite, spriteName, spriteNameOf, properties, has, couldBePowered, consumption;
    private final Object waterPiped;
    private final Object[] attached;
    private static final int[][] ACROSS = { { 0, -1 }, { 0, 1 }, { 1, 0 }, { -1, 0 } };
    private static final int[] NONE = {};

    /**
     * What a sprite says of the objects that have it: the wall it hangs on, as the step to the square across ({ dx, dy },
     * or none), and whether the game can pipe water to it. Sprites are few and shared, and the hooks ask often.
     */
    private record Facts(int[] across, boolean piped) { }
    private final Map<Object, Facts> facts = new ConcurrentHashMap<>();

    Buildings(Kahlua lua, Game game, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        Class<?> grid = Game.type(loader, "zombie.iso.IsoMetaGrid");
        Class<?> room = Game.type(loader, "zombie.iso.RoomDef"), rect = Game.type(loader, "zombie.iso.RoomDef$RoomRect");
        Class<?> def = Game.type(loader, "zombie.iso.BuildingDef"), object = game.objectType;
        Class<?> sprite = Game.type(loader, "zombie.iso.sprite.IsoSprite");
        Class<?> container = Game.type(loader, "zombie.core.properties.PropertyContainer");
        Class<?> flag = Game.type(loader, "zombie.iso.SpriteDetails.IsoFlagType");
        roomAt = grid.getMethod("getRoomAt", int.class, int.class, int.class);
        roomById = grid.getMethod("getRoomDefByID", long.class);
        building = room.getMethod("getBuilding");
        roomName = room.getMethod("getName");
        roomLevel = room.getMethod("getZ");
        roomRects = room.getMethod("getRects");
        roomId = room.getMethod("getID");
        rooms = def.getMethod("getRooms");
        userDefined = def.getMethod("isUserDefined");
        rectX = rect.getMethod("getX"); rectY = rect.getMethod("getY");
        rectW = rect.getMethod("getW"); rectH = rect.getMethod("getH");
        objectSprite = object.getMethod("getSprite");
        spriteName = object.getMethod("getSpriteName");
        spriteNameOf = sprite.getMethod("getName");
        properties = sprite.getMethod("getProperties");
        has = container.getMethod("has", flag);
        couldBePowered = object.getMethod("couldBePoweredByGenerator");
        consumption = object.getMethod("getGeneratorPowerConsumption");
        waterPiped = flag.getField("waterPiped").get(null);
        attached = new Object[] { flag.getField("attachedN").get(null), flag.getField("attachedS").get(null),
            flag.getField("attachedE").get(null), flag.getField("attachedW").get(null) };
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

    /** An object that uses power or water, on a loaded square; {@code room} is the room it belongs to, if any. */
    record Found(Object object, int x, int y, int z, Object room, boolean power, boolean water) { }

    private Object at(int x, int y, int z) throws ReflectiveOperationException {
        Object room = roomAt(x, y, z);
        Building found = room == null ? null : describe(building.invoke(room));
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
            lua.set(entry, "level", (double)(int)roomLevel.invoke(room));
            var rects = new ArrayList<Object>();
            for (Rect rect : rects(room)) {
                Object value = lua.table();
                lua.set(value, "x", (double)rect.x()); lua.set(value, "y", (double)rect.y());
                lua.set(value, "w", (double)rect.w()); lua.set(value, "h", (double)rect.h());
                rects.add(value);
            }
            lua.set(entry, "rects", lua.list(rects));
            result.add(entry);
        }
        return lua.list(result);
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
        for (int z = found.minLevel(); z <= found.maxLevel(); z++)
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
        Object cells = game.cell(), grid = game.metaGrid();
        int left = found.minX() - tiles, top = found.minY() - tiles;
        int width = found.maxX() - found.minX() + 1 + 2 * tiles, height = found.maxY() - found.minY() + 1 + 2 * tiles;
        var result = new ArrayList<Object>();
        boolean complete = true;
        for (int z = found.minLevel(); z <= found.maxLevel(); z++) {
            boolean[] inside = new boolean[width * height];
            boolean any = false;
            for (Object room : found.rooms()) {
                if ((int)roomLevel.invoke(room) != z) continue;
                for (Rect rect : rects(room))
                    for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                        for (int x = rect.x(); x < rect.x() + rect.w(); x++) { inside[(y - top) * width + x - left] = true; any = true; }
            }
            if (!any) continue;
            boolean[] ring = dilate(inside, width, height, tiles);
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++) {
                    if (!ring[y * width + x] || inside[y * width + x]) continue;
                    int wx = left + x, wy = top + y;
                    if (roomAt(grid, wx, wy, z) != null) continue;
                    Object loaded = game.square(cells, wx, wy, z);
                    if (loaded == null) { complete = false; continue; }
                    for (Object object : game.objectsOn(loaded)) {
                        if (owner(grid, object, null, wx, wy, z) != null) continue;
                        Found thing = classify(object, filter, wx, wy, z, null);
                        if (thing != null) result.add(entry(thing));
                    }
                }
        }
        return new Object[] { lua.list(result), complete };
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
        if (squareRoom != null) return squareRoom;
        int[] step = across(object);
        return step.length == 0 ? null : roomAt(grid, x + step[0], y + step[1], z);
    }

    /**
     * The square an object counts as standing in: its own, or, for one on a square of no room that hangs on a wall
     * (its sprite is attached north, south, east or west) with a room across it, the square across. A lamp on a
     * building's outer wall stands outside, on the square beyond the wall, but is the building's.
     */
    Position home(Object object, Position at) throws ReflectiveOperationException {
        if (at == null) return null;
        int[] step = homeStep(object, at.x(), at.y(), at.z());
        return step == null ? at : new Position(at.x() + step[0], at.y() + step[1], at.z());
    }

    /**
     * {@link #home} without allocating: the step to the square across the wall the object hangs on, when it counts as
     * standing there; null for its own square. An object that hangs on no wall, as most do, costs a look at its sprite.
     */
    int[] homeStep(Object object, int x, int y, int z) throws ReflectiveOperationException {
        int[] step = across(object);
        if (step.length == 0) return null;
        Object grid = game.metaGrid();
        return roomAt(grid, x, y, z) == null && roomAt(grid, x + step[0], y + step[1], z) != null ? step : null;
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

    /** The name objects are known by: the object's sprite name, or its sprite's. */
    String sprite(Object object) throws ReflectiveOperationException {
        Object name = spriteName.invoke(object);
        if (name == null) {
            Object sprite = objectSprite.invoke(object);
            if (sprite != null) name = spriteNameOf.invoke(sprite);
        }
        return (String)name;
    }

    /** What the game gives for the object's power use now. */
    float consumption(Object object) throws ReflectiveOperationException { return (float)consumption.invoke(object); }

    /** The building a key names, or null when no building has that key now (it was rebuilt, or removed). */
    private Building resolve(String key) throws ReflectiveOperationException {
        String[] parts = key.split(",", -1);
        if (parts.length != 3) return null;
        int x, y, z;
        try { x = Integer.parseInt(parts[0]); y = Integer.parseInt(parts[1]); z = Integer.parseInt(parts[2]); }
        catch (NumberFormatException notAKey) { return null; }
        Object room = roomAt(x, y, z);
        Building found = room == null ? null : describe(building.invoke(room));
        return found != null && found.key().equals(key) ? found : null;
    }

    /** The building the square belongs to now, or null. */
    Building buildingAt(int x, int y, int z) throws ReflectiveOperationException {
        Object room = roomAt(x, y, z);
        return room == null ? null : describe(building.invoke(room));
    }

    /** The room the square belongs to now (a RoomDef), or null. */
    Object roomOf(int x, int y, int z) throws ReflectiveOperationException { return roomAt(x, y, z); }

    /** The building of a room, as its rooms describe it now. */
    Building buildingOf(Object room) throws ReflectiveOperationException { return describe(building.invoke(room)); }

    /** The building narrowed to some of its rooms, in its own order: what a network takes of it. */
    static Building narrowed(Building whole, Set<Object> rooms) {
        var kept = new ArrayList<Object>();
        for (Object room : whole.rooms()) if (rooms.contains(room)) kept.add(room);
        return new Building(whole.def(), List.copyOf(kept), whole.key(), whole.minLevel(), whole.maxLevel(),
            whole.minX(), whole.minY(), whole.maxX(), whole.maxY());
    }

    int level(Object room) throws ReflectiveOperationException { return (int)roomLevel.invoke(room); }

    long roomId(Object room) throws ReflectiveOperationException { return (long)roomId.invoke(room); }

    private Building describe(Object def) throws ReflectiveOperationException {
        if (def == null) return null;
        var list = new ArrayList<Object>((List<?>)rooms.invoke(def));
        int minLevel = Integer.MAX_VALUE, maxLevel = Integer.MIN_VALUE;
        int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE, maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE;
        int keyX = 0, keyY = 0;
        for (Object room : list) {
            int level = (int)roomLevel.invoke(room);
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
        for (Object rect : (List<?>)roomRects.invoke(room)) {
            int w = (int)rectW.invoke(rect), h = (int)rectH.invoke(rect);
            if (w > 0 && h > 0) result.add(new Rect((int)rectX.invoke(rect), (int)rectY.invoke(rect), w, h));
        }
        return result;
    }

    private Object roomAt(int x, int y, int z) throws ReflectiveOperationException { return roomAt(game.metaGrid(), x, y, z); }

    /** The room at the square, from the meta grid a caller that asks about many squares got once. */
    private Object roomAt(Object grid, int x, int y, int z) throws ReflectiveOperationException {
        return grid == null ? null : roomAt.invoke(grid, x, y, z);
    }
}
