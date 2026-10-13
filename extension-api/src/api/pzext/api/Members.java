package pzext.api;

import java.util.*;
import pzext.api.Network.Position;
import pzext.api.Network.Thing;

/**
 * What a network takes in, as the map has it now: the squares of its member buildings, and the objects in them that
 * use its utility, but those excluded, and the objects added on their own. Shared by the power and the water networks.
 */
final class Members {
    /**
     * The squares of a network's buildings: one bit per square, in blocks of 8 by 8 squares of one level, kept only for
     * the blocks a room reaches. Its memory follows the buildings' size, not how far apart they are. {@code shell}, the
     * same for the squares of no room that count as in one of its rooms (Buildings.shellStep): its roofs and the squares
     * against its walls, those no other building's room has first.
     */
    record Area(SquareMap blocks, SquareMap shell) {
        boolean contains(int x, int y, int z) { return has(blocks, x, y, z); }

        boolean contains(Position at) { return contains(at.x(), at.y(), at.z()); }

        boolean shelters(int x, int y, int z) { return has(shell, x, y, z); }

        private static boolean has(SquareMap map, int x, int y, int z) {
            long block = map.get(x >> 3, y >> 3, z, 0);
            return (block >>> ((y & 7) << 3 | x & 7) & 1) != 0;
        }

        private static void mark(Map<Position, Long> map, int x, int y, int z) {
            map.merge(new Position(x >> 3, y >> 3, z), 1L << ((y & 7) << 3 | x & 7), (a, b) -> a | b);
        }

        /**
         * Worked out as the buildings are resolved: the rooms' squares, then the shell around them. Only the squares
         * beside a room or over it that are in none of these rooms are looked up on the map.
         */
        static Area of(List<Buildings.Building> found, Buildings buildings) throws ReflectiveOperationException {
            if (found.isEmpty()) return null;
            var blocks = new HashMap<Position, Long>();
            var rooms = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
            for (var building : found)
                for (Object room : building.rooms()) {
                    rooms.add(room);
                    int z = buildings.level(room);
                    for (var rect : buildings.rects(room))
                        for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                            for (int x = rect.x(); x < rect.x() + rect.w(); x++) mark(blocks, x, y, z);
                }
            var inside = new SquareMap(blocks);
            // Around each room's squares on its level, and over them.
            var shell = new HashMap<Position, Long>();
            var looked = new HashSet<Position>();
            for (Object room : rooms) {
                int level = buildings.level(room);
                for (var rect : buildings.rects(room))
                    for (int y = rect.y() - 1; y <= rect.y() + rect.h(); y++)
                        for (int x = rect.x() - 1; x <= rect.x() + rect.w(); x++)
                            for (int z = level; z <= level + 1; z++) {
                                boolean over = x >= rect.x() && x < rect.x() + rect.w() && y >= rect.y() && y < rect.y() + rect.h();
                                if (z > level && !over || has(inside, x, y, z) || !looked.add(new Position(x, y, z))) continue;
                                Object owner = buildings.shellRoom(x, y, z);
                                if (owner != null && rooms.contains(owner)) mark(shell, x, y, z);
                            }
            }
            return new Area(inside, shell.isEmpty() ? SquareMap.EMPTY : new SquareMap(shell));
        }
    }

    static final Buildings.Filter POWER = new Buildings.Filter(true, false), WATER = new Buildings.Filter(false, true);

    private final Game game;
    private final Buildings buildings;

    Members(Game game, Buildings buildings) {
        this.game = game;
        this.buildings = buildings;
    }

    /**
     * The member buildings as the map data has them now; a player-built one is made again when its walls change. A
     * building named by rooms alone, and not as a whole, is narrowed to those rooms. Asked once a second: a building is
     * described once for each version of the buildings (Buildings.observe), so each room named costs two lookups.
     */
    void resolve(Network network) throws ReflectiveOperationException {
        var found = new ArrayList<Buildings.Building>();
        for (Position at : network.buildings) {
            var building = buildings.buildingAt(at.x(), at.y(), at.z());
            if (building != null && found.stream().noneMatch(other -> other.def() == building.def())) found.add(building);
        }
        var narrowed = new ArrayList<Buildings.Building>();
        var rooms = new IdentityHashMap<Object, Set<Object>>();
        for (Position at : network.rooms) {
            Object room = buildings.roomOf(at.x(), at.y(), at.z());
            var building = room == null ? null : buildings.buildingOf(room);
            if (building == null || found.stream().anyMatch(other -> other.def() == building.def())) continue;
            if (!rooms.containsKey(building.def())) {
                rooms.put(building.def(), Collections.newSetFromMap(new IdentityHashMap<>()));
                narrowed.add(building);
            }
            rooms.get(building.def()).add(room);
        }
        for (var building : narrowed) found.add(Buildings.narrowed(building, rooms.get(building.def())));
        boolean same = found.size() == network.resolved.size();
        for (int index = 0; same && index < found.size(); index++)
            same = found.get(index).def() == network.resolved.get(index).def()
                && found.get(index).rooms().equals(network.resolved.get(index).rooms());
        if (same) return;
        network.resolved = List.copyOf(found);
        network.area = Area.of(found, buildings);
        network.loadChanged = true;
    }

    /**
     * The network's consumers on loaded squares: the objects of its buildings that use what the filter asks for, but
     * those excluded, and the objects added on their own. {@code complete[0]} is cleared when some were not loaded.
     */
    List<Buildings.Found> consumers(Network network, Buildings.Filter filter, boolean[] complete) throws ReflectiveOperationException {
        return consumers(network, filter, complete, null);
    }

    /** As {@link #consumers(Network, Buildings.Filter, boolean[])}, adding to {@code missing} the chunks of the squares not loaded. */
    List<Buildings.Found> consumers(Network network, Buildings.Filter filter, boolean[] complete, Set<Long> missing)
            throws ReflectiveOperationException {
        var result = new ArrayList<Buildings.Found>();
        var seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        for (var building : network.resolved)
            for (var found : buildings.scan(building, filter, complete, missing))
                if (!excluded(network, found.object()) && seen.add(found.object())) result.add(found);
        Object cells = game.cell();
        for (Thing thing : network.included) {
            Object loaded = game.square(cells, thing.at());
            if (loaded == null) {
                complete[0] = false;
                if (missing != null) missing.add(game.chunkKey(thing.at().x(), thing.at().y()));
                continue;
            }
            for (Object object : game.objectsOn(loaded)) {
                if (!thing.sprite().equals(buildings.sprite(object))) continue;
                var found = buildings.classify(object, filter, thing.at().x(), thing.at().y(), thing.at().z(), null);
                if (found != null && seen.add(object)) result.add(found);
            }
        }
        return result;
    }

    /** Whether the network excludes the object: one of its squares, for an object that covers several. */
    private boolean excluded(Network network, Object object) throws ReflectiveOperationException {
        if (network.excluded.isEmpty()) return false;
        for (Object part : game.parts(object)) {
            Position at = game.at(part);
            String sprite = at == null ? null : buildings.sprite(part);
            if (sprite != null && network.excluded.contains(new Thing(at, sprite))) return true;
        }
        return false;
    }
}
