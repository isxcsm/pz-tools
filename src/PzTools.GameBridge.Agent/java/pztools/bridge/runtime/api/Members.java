package pztools.bridge.runtime.api;

import java.lang.reflect.*;
import java.util.*;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Thing;

/**
 * What a network takes in, as the map has it now: the squares of its member buildings, and the objects in them that
 * use its utility, but those excluded, and the objects added on their own. Shared by the power and the water networks.
 */
final class Members {
    /** The squares of a network's buildings: one bit per square, over the box around them. */
    record Area(int minX, int minY, int minZ, int width, int height, int levels, long[] bits) {
        boolean contains(int x, int y, int z) {
            int dx = x - minX, dy = y - minY, dz = z - minZ;
            if (dx < 0 || dy < 0 || dz < 0 || dx >= width || dy >= height || dz >= levels) return false;
            int index = (dz * height + dy) * width + dx;
            return (bits[index >>> 6] & 1L << index) != 0;
        }

        boolean contains(Position at) { return contains(at.x(), at.y(), at.z()); }

        static Area of(List<Buildings.Building> found, Buildings buildings) throws ReflectiveOperationException {
            if (found.isEmpty()) return null;
            int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE, minZ = Integer.MAX_VALUE;
            int maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE, maxZ = Integer.MIN_VALUE;
            for (var building : found) {
                minX = Math.min(minX, building.minX()); minY = Math.min(minY, building.minY()); minZ = Math.min(minZ, building.minLevel());
                maxX = Math.max(maxX, building.maxX()); maxY = Math.max(maxY, building.maxY()); maxZ = Math.max(maxZ, building.maxLevel());
            }
            int width = maxX - minX + 1, height = maxY - minY + 1, levels = maxZ - minZ + 1;
            long[] bits = new long[(int)(((long)width * height * levels + 63) / 64)];
            for (var building : found)
                for (Object room : building.rooms()) {
                    int dz = buildings.level(room) - minZ;
                    for (var rect : buildings.rects(room))
                        for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                            for (int x = rect.x(); x < rect.x() + rect.w(); x++) {
                                int index = (dz * height + y - minY) * width + x - minX;
                                bits[index >>> 6] |= 1L << index;
                            }
                }
            return new Area(minX, minY, minZ, width, height, levels, bits);
        }
    }

    static final Buildings.Filter POWER = new Buildings.Filter(true, false), WATER = new Buildings.Filter(false, true);

    private final Buildings buildings;
    private final Map<String, Network> networks;
    private final Method square, objectSquare, hasGrid, gridObjects;
    private final Field squareX, squareY, squareZ;

    Members(ClassLoader loader, Buildings buildings, Map<String, Network> networks) throws ReflectiveOperationException {
        this.buildings = buildings;
        this.networks = networks;
        Class<?> squareType = Class.forName("zombie.iso.IsoGridSquare", false, loader);
        Class<?> objectType = Class.forName("zombie.iso.IsoObject", false, loader);
        square = Class.forName("zombie.iso.IsoCell", false, loader).getMethod("getGridSquare", int.class, int.class, int.class);
        squareX = squareType.getField("x"); squareY = squareType.getField("y"); squareZ = squareType.getField("z");
        objectSquare = objectType.getMethod("getSquare");
        hasGrid = objectType.getMethod("hasSpriteGrid");
        gridObjects = objectType.getMethod("getSpriteGridObjectsIncludingSelf", ArrayList.class);
    }

    Buildings buildings() { return buildings; }

    /** The networks of one utility, in the order they were defined. */
    List<Network> of(String utility) {
        var result = new ArrayList<Network>();
        for (Network network : networks.values()) if (network.utility.equals(utility)) result.add(network);
        return result;
    }

    /** The network at the top of a child's parents; null when a parent is missing. */
    Network root(Network network) {
        for (int depth = 0; network != null && depth <= networks.size(); depth++) {
            if (network.parent == null) return network;
            network = networks.get(network.parent);
        }
        return null;
    }

    /** Whether the network and every parent above it are switched on. */
    boolean switchedOn(Network network) {
        for (int depth = 0; network != null && depth <= networks.size(); depth++) {
            if (!network.enabled) return false;
            if (network.parent == null) return true;
            network = networks.get(network.parent);
        }
        return false;
    }

    /** The network and its parents, up to the one at the top. */
    List<Network> chain(Network network) {
        var result = new ArrayList<Network>();
        for (int depth = 0; network != null && depth <= networks.size(); depth++) {
            result.add(network);
            network = network.parent == null ? null : networks.get(network.parent);
        }
        return result;
    }

    /** The game's current cell, or null when no world is loaded. */
    Object cell() throws ReflectiveOperationException { return buildings.cell(); }

    /** The loaded square, or null. */
    Object square(Object cells, Position at) throws ReflectiveOperationException {
        return cells == null ? null : square.invoke(cells, at.x(), at.y(), at.z());
    }

    /**
     * The member buildings as the map data has them now; a player-built one is made again when its walls change. A
     * building named by rooms alone, and not as a whole, is narrowed to those rooms.
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
        var result = new ArrayList<Buildings.Found>();
        var seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        for (var building : network.resolved)
            for (var found : buildings.scan(building, filter, complete))
                if (!excluded(network, found.object()) && seen.add(found.object())) result.add(found);
        Object cells = cell();
        for (Thing thing : network.included) {
            Object loaded = square(cells, thing.at());
            if (loaded == null) { complete[0] = false; continue; }
            for (Object object : buildings.objectsOn(loaded)) {
                if (!thing.sprite().equals(buildings.sprite(object))) continue;
                var found = buildings.classify(object, filter, thing.at().x(), thing.at().y(), thing.at().z(), null);
                if (found != null && seen.add(object)) result.add(found);
            }
        }
        return result;
    }

    /** Whether the network excludes the object: one of its squares, for an object that covers several. */
    boolean excluded(Network network, Object object) throws ReflectiveOperationException {
        if (network.excluded.isEmpty()) return false;
        for (Object part : parts(object)) {
            Thing thing = thing(part);
            if (thing != null && network.excluded.contains(thing)) return true;
        }
        return false;
    }

    /** The object and, for one that covers several squares, its other parts. */
    List<Object> parts(Object object) throws ReflectiveOperationException {
        if (!(boolean)hasGrid.invoke(object)) return List.of(object);
        @SuppressWarnings("unchecked")
        var parts = (List<Object>)gridObjects.invoke(object, new ArrayList<>());
        return parts.isEmpty() ? List.of(object) : parts;
    }

    /** The object as its square and sprite, or null when it is on no square or has no sprite. */
    Thing thing(Object object) throws ReflectiveOperationException {
        Position at = at(object);
        String sprite = at == null ? null : buildings.sprite(object);
        return sprite == null ? null : new Thing(at, sprite);
    }

    /** The object's square, or null when it is on none. */
    Position at(Object object) throws ReflectiveOperationException { return position(objectSquare.invoke(object)); }

    Position position(Object loaded) throws IllegalAccessException {
        return loaded == null ? null : new Position(squareX.getInt(loaded), squareY.getInt(loaded), squareZ.getInt(loaded));
    }
}
