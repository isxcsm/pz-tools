package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import pzext.api.Buildings.Building;

/**
 * {@code PZExtAPI.buildings.list}: the map's buildings whose middle lies in a ring round a point, each with the facts a mod picks one
 * by (docs/design.md, "Map facts"). Read from the meta grid, loaded and unloaded parts alike, in Java: a mod that picks a site walks
 * thousands of buildings, and in Lua each is half a dozen game calls and a table.
 *
 * <p>What a building is (its key, box, levels, area, middle and rooms' names) does not change while its world and its rooms are the
 * same, so it is worked out once for each map building and kept with the meta grid and the buildings' {@link Buildings#epoch()}: another
 * world or new rooms (setRooms) take it away. The buildings players made are described again at each call, as {@link Buildings} keeps
 * them. What a game changes as it goes (a building visited, a stash) is asked live, only of a building that passed the rest.
 *
 * <p>The list is in the meta grid's own order and sorted by nothing. A building is where its rooms are ({@link Buildings}), so one with
 * no room that has a square is not listed.
 */
final class BuildingLists {
    static final String KEY = "buildingListGeneration";
    private static final String AREA = "PZExtAPI.buildings.list";
    private static final double LIMIT = 1e9;

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final Generation generation;
    // IsoMetaGrid.getBuildings(); BuildingDef.getArea(), isBasement(), isHasBeenVisited(); StashSystem.isStashBuilding(def).
    private final MethodHandle all, area, basement, visited, stash;

    /** What a building is, as long as its world and rooms are the same. */
    private static final class Facts {
        final Object def;
        final Building building;
        final int x, y, area;
        final boolean basement;
        // Its rooms' names, once asked for.
        String[] names;

        Facts(Object def, Building building, int x, int y, int area, boolean basement) {
            this.def = def; this.building = building; this.x = x; this.y = y; this.area = area; this.basement = basement;
        }
    }

    /** A filter: the facts a building must have; a key left out is not tested. */
    private record Wanted(int minArea, Boolean basement, Boolean playerBuilt, Boolean visited, Boolean stash, boolean names) { }

    // Kept for the meta grid and epoch they were made in; the identity map is by the definition (a BuildingDef).
    private final IdentityHashMap<Object, Facts> known = new IdentityHashMap<>();
    private Object grid;
    private long epoch = -1;
    private static final Facts NONE = new Facts(null, null, 0, 0, 0, false);

    BuildingLists(Kahlua lua, Game game, Buildings buildings, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        generation = new Generation(lua, meta, KEY);
        Class<?> def = Game.type(loader, "zombie.iso.BuildingDef");
        MethodType flag = MethodType.methodType(boolean.class, Object.class);
        all = Game.exact(Game.type(loader, "zombie.iso.IsoMetaGrid").getMethod("getBuildings"), MethodType.methodType(List.class, Object.class));
        area = Game.exact(def.getMethod("getArea"), MethodType.methodType(int.class, Object.class));
        basement = Game.exact(def.getMethod("isBasement"), flag);
        visited = Game.exact(def.getMethod("isHasBeenVisited"), flag);
        stash = Game.exact(Game.type(loader, "zombie.core.stash.StashSystem").getMethod("isStashBuilding", def), flag);
    }

    /** Sets the function into the buildings' table. */
    void register(Object table) throws ReflectiveOperationException {
        generation.start();
        lua.set(table, "list", lua.function(AREA, arguments -> {
            generation.check(AREA);
            return new Object[] { list(arguments) };
        }));
    }

    private synchronized Object list(Object[] arguments) throws ReflectiveOperationException {
        double x = Arguments.number(arguments, 0, AREA, "x", -LIMIT, LIMIT), y = Arguments.number(arguments, 1, AREA, "y", -LIMIT, LIMIT);
        double lo = Arguments.number(arguments, 2, AREA, "lo", 0, LIMIT), hi = Arguments.number(arguments, 3, AREA, "hi", 0, LIMIT);
        if (lo > hi) throw new IllegalArgumentException(AREA + ": lo must not be more than hi");
        Wanted wanted = wanted(arguments.length > 4 ? arguments[4] : null);
        buildings.observe();
        Object meta = game.metaGrid();
        var found = new ArrayList<Object>();
        if (meta != null) {
            if (meta != grid || buildings.epoch() != epoch) {
                known.clear();
                grid = meta;
                epoch = buildings.epoch();
            }
            double near = lo * lo, far = hi * hi;
            try {
                List<?> map = (List<?>)all.invokeExact(meta);
                for (int index = 0, size = map.size(); index < size; index++) {
                    Object def = map.get(index);
                    Facts facts = known.get(def);
                    if (facts == null) {
                        facts = facts(def);
                        // What players built is described again at each call; a definition without rooms may get some.
                        if (facts != NONE && !facts.building.playerBuilt()) known.put(def, facts);
                    }
                    if (facts == NONE) continue;
                    double dx = facts.x - x, dy = facts.y - y, squared = dx * dx + dy * dy;
                    if (squared < near || squared > far || !passes(facts, wanted)) continue;
                    found.add(entry(facts, Math.sqrt(squared), wanted.names()));
                }
            } catch (Throwable failure) { throw Game.thrown(failure); }
        }
        return lua.list(found);
    }

    /** The building's facts, or {@link #NONE} for a definition with no room that has a square. */
    private Facts facts(Object def) throws Throwable {
        Building building = buildings.describing(def);
        if (building == null) return NONE;
        // Its middle, as the mods work it out from the definition's box (x + x2) / 2, whose x2 is one past the last square.
        return new Facts(def, building, Math.floorDiv(building.minX() + building.maxX() + 1, 2),
            Math.floorDiv(building.minY() + building.maxY() + 1, 2), (int)area.invokeExact(def), (boolean)basement.invokeExact(def));
    }

    /** The cheap, kept facts first; what the game changes as it goes is asked of the building that passed them. */
    private boolean passes(Facts facts, Wanted wanted) throws Throwable {
        if (wanted.minArea() > 0 && facts.area < wanted.minArea()) return false;
        if (wanted.basement() != null && wanted.basement() != facts.basement) return false;
        if (wanted.playerBuilt() != null && wanted.playerBuilt() != facts.building.playerBuilt()) return false;
        if (wanted.visited() != null && wanted.visited() != (boolean)visited.invokeExact(facts.def)) return false;
        if (wanted.stash() != null && wanted.stash() != stashing(facts.def)) return false;
        return true;
    }

    /** Whether the game keeps a stash in the building; a fault of the game's is taken as none, as the mods' protected call does. */
    private boolean stashing(Object def) {
        try { return (boolean)stash.invokeExact(def); }
        catch (Throwable failure) {
            if (failure instanceof Error error) throw error;
            return false;
        }
    }

    private Object entry(Facts facts, double distance, boolean names) throws ReflectiveOperationException {
        Object result = lua.table();
        Building building = facts.building;
        lua.set(result, "key", building.key());
        lua.set(result, "x", (double)facts.x);
        lua.set(result, "y", (double)facts.y);
        lua.set(result, "distance", distance);
        lua.set(result, "area", (double)facts.area);
        lua.set(result, "minX", (double)building.minX());
        lua.set(result, "minY", (double)building.minY());
        lua.set(result, "maxX", (double)building.maxX());
        lua.set(result, "maxY", (double)building.maxY());
        lua.set(result, "minLevel", (double)building.minLevel());
        lua.set(result, "maxLevel", (double)building.maxLevel());
        if (names) {
            if (facts.names == null) {
                var rooms = building.rooms();
                facts.names = new String[rooms.size()];
                for (int index = 0; index < facts.names.length; index++) {
                    String name = buildings.roomName(rooms.get(index));
                    facts.names[index] = name == null ? "" : name;
                }
            }
            Object list = lua.table();
            for (int index = 0; index < facts.names.length; index++) lua.setAt(list, index + 1, facts.names[index]);
            lua.set(result, "roomNames", list);
        }
        return result;
    }

    private Wanted wanted(Object filter) throws ReflectiveOperationException {
        if (filter == null) return new Wanted(0, null, null, null, null, false);
        if (!lua.isTable(filter)) throw new IllegalArgumentException(AREA + ": filter must be a table");
        Object minArea = lua.get(filter, "minArea");
        if (minArea != null && !(minArea instanceof Double)) throw new IllegalArgumentException(AREA + ": filter.minArea must be a number");
        Object names = lua.get(filter, "roomNames");
        return new Wanted(minArea == null ? 0 : (int)Math.ceil((Double)minArea), flag(filter, "basement"), flag(filter, "playerBuilt"),
            flag(filter, "visited"), flag(filter, "stash"), names != null && !Boolean.FALSE.equals(names));
    }

    private Boolean flag(Object filter, String name) throws ReflectiveOperationException {
        Object value = lua.get(filter, name);
        if (value != null && !(value instanceof Boolean)) throw new IllegalArgumentException(AREA + ": filter." + name + " must be true or false");
        return (Boolean)value;
    }
}
