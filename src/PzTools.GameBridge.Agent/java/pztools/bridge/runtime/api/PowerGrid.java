package pztools.bridge.runtime.api;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import pztools.bridge.ApiHooks;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Thing;

/**
 * Runs the power networks (docs/design/extension-api.md, "Power"): answers the game's power questions through the
 * hooks, keeps the generators of a network from powering their surroundings, and works out each network's supply and
 * load. The hooks read an immutable snapshot, so a question asked on any thread costs a lookup; everything else runs on
 * the game's thread, once a second or when something changed.
 */
final class PowerGrid implements ApiHooks.Power {
    private static final long REFRESH_NANOS = TimeUnit.SECONDS.toNanos(1);
    // A network whose consumers were not all loaded is worked out again this often, until they were.
    private static final long INCOMPLETE_LOAD_NANOS = TimeUnit.SECONDS.toNanos(5);
    private static final Buildings.Filter POWER = new Buildings.Filter(true, false);
    // Set while the game's own answer is asked again for an excluded object: the networks then give no square power.
    private static final ThreadLocal<boolean[]> PURE = ThreadLocal.withInitial(() -> new boolean[1]);

    /** The squares of a network's buildings: one bit per square, over the box around them. */
    record Area(int minX, int minY, int minZ, int width, int height, int levels, long[] bits) {
        boolean contains(int x, int y, int z) {
            int dx = x - minX, dy = y - minY, dz = z - minZ;
            if (dx < 0 || dy < 0 || dz < 0 || dx >= width || dy >= height || dz >= levels) return false;
            int index = (dz * height + dy) * width + dx;
            return (bits[index >>> 6] & 1L << index) != 0;
        }

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

    /** An object rule of a network at one square. */
    private record Rule(String sprite, boolean included, boolean supplied, Network network) { }

    /** What the hooks read. {@code supplied} holds the areas of the networks that have supply now. */
    private record Snapshot(Area[] supplied, List<Network> withArea, Map<Position, Network> producers,
            Map<Position, List<Rule>> rules) {
        static final Snapshot EMPTY = new Snapshot(new Area[0], List.of(), Map.of(), Map.of());
    }

    private final Buildings buildings;
    private final Map<String, Network> networks;
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change and by the hooks; the next frame works the networks out again.
    private volatile boolean changed = true;
    private long refreshedAt = Long.MIN_VALUE;

    private final Method cell, getChunk, square, generatorOf, objectSquare, checkElectricity, hasGrid, gridObjects;
    private final Field squareX, squareY, squareZ, squareChunk, chunkX, chunkY;
    private final Method removeGeneratorPos, activated, fuel, condition, setUsing, surroundings;
    // The getter gives the consumption times the sandbox's fuel rate; the field is what setTotalPowerUsing set.
    private final Field itemsPowered, using, chunkRange, basePower, worldInstance;
    private final Method containerPowered, switchPowered, devicePowered, battery, deviceParent;
    private final Class<?> objectType;

    PowerGrid(ClassLoader loader, Buildings buildings, Map<String, Network> networks) throws ReflectiveOperationException {
        this.buildings = buildings;
        this.networks = networks;
        Class<?> worldType = type(loader, "zombie.iso.IsoWorld"), cellType = type(loader, "zombie.iso.IsoCell");
        Class<?> squareType = type(loader, "zombie.iso.IsoGridSquare"), chunkType = type(loader, "zombie.iso.IsoChunk");
        Class<?> generator = type(loader, "zombie.iso.objects.IsoGenerator");
        Class<?> lightSwitch = type(loader, "zombie.iso.objects.IsoLightSwitch");
        Class<?> device = type(loader, "zombie.radio.devices.DeviceData");
        objectType = type(loader, "zombie.iso.IsoObject");
        cell = worldType.getMethod("getCell");
        getChunk = cellType.getMethod("getChunk", int.class, int.class);
        square = cellType.getMethod("getGridSquare", int.class, int.class, int.class);
        generatorOf = squareType.getMethod("getGenerator");
        squareX = squareType.getField("x"); squareY = squareType.getField("y"); squareZ = squareType.getField("z");
        squareChunk = squareType.getField("chunk");
        chunkX = chunkType.getField("wx"); chunkY = chunkType.getField("wy");
        removeGeneratorPos = chunkType.getMethod("removeGeneratorPos", int.class, int.class, int.class);
        objectSquare = objectType.getMethod("getSquare");
        checkElectricity = objectType.getMethod("checkHaveElectricity");
        hasGrid = objectType.getMethod("hasSpriteGrid");
        gridObjects = objectType.getMethod("getSpriteGridObjectsIncludingSelf", ArrayList.class);
        activated = generator.getMethod("isActivated");
        fuel = generator.getMethod("getFuel");
        condition = generator.getMethod("getCondition");
        setUsing = generator.getMethod("setTotalPowerUsing", float.class);
        using = accessible(generator.getDeclaredField("totalPowerUsing"));
        surroundings = generator.getMethod("setSurroundingElectricity");
        itemsPowered = accessible(generator.getDeclaredField("itemsPowered"));
        chunkRange = accessible(generator.getDeclaredField("generatorChunkRange"));
        basePower = accessible(generator.getDeclaredField("GeneratorBasePowerConsumption"));
        containerPowered = type(loader, "zombie.inventory.ItemContainer").getMethod("isObjectPowered", objectType, boolean.class);
        switchPowered = accessible(lightSwitch.getDeclaredMethod("hasElectricityAround"));
        devicePowered = device.getMethod("canBePoweredHere");
        battery = device.getMethod("getIsBatteryPowered");
        deviceParent = device.getMethod("getParent");
        worldInstance = worldType.getField("instance");
    }

    private static Class<?> type(ClassLoader loader, String name) throws ClassNotFoundException {
        return Class.forName(name, false, loader);
    }

    private static <T extends AccessibleObject> T accessible(T member) { member.setAccessible(true); return member; }

    /** A definition changed: the next frame works the networks out again. */
    void changed() { changed = true; }

    /** The game's current cell, or null when no world is loaded. */
    Object cell() throws ReflectiveOperationException {
        Object world = worldInstance.get(null);
        return world == null ? null : cell.invoke(world);
    }

    // The hooks.

    @Override public boolean square(int x, int y, int z) {
        for (Area area : snapshot.supplied()) if (area.contains(x, y, z)) return !PURE.get()[0];
        return false;
    }

    @Override public boolean object(boolean vanilla, Object object, int kind, boolean generators) {
        if (!generators || object == null) return vanilla;
        Snapshot current = snapshot;
        if (current.rules().isEmpty()) return vanilla;
        boolean[] pure = PURE.get();
        if (pure[0]) return vanilla;
        try {
            Object target = object;
            if (kind == ApiHooks.DEVICE) {
                if ((boolean)battery.invoke(object)) return vanilla;
                target = deviceParent.invoke(object);
                if (!objectType.isInstance(target)) return vanilla;
            }
            boolean excluded = false;
            for (Object part : parts(target)) {
                Thing thing = thing(part);
                List<Rule> rules = thing == null ? null : current.rules().get(thing.at());
                if (rules == null) continue;
                for (Rule rule : rules) {
                    if (!rule.sprite().equals(thing.sprite())) continue;
                    if (rule.included() && rule.supplied()) return true;
                    if (!rule.included()) excluded = true;
                }
            }
            if (!excluded || !vanilla) return vanilla;
            // The game said yes, perhaps because a network powers the square: ask it again without the networks.
            pure[0] = true;
            try {
                return switch (kind) {
                    case ApiHooks.APPLIANCE -> (boolean)containerPowered.invoke(null, object, true);
                    case ApiHooks.LIGHT_SWITCH -> (boolean)switchPowered.invoke(object);
                    default -> (boolean)devicePowered.invoke(object);
                };
            } finally { pure[0] = false; }
        } catch (InvocationTargetException failure) {
            throw new IllegalStateException(failure.getCause());
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException(failure);
        }
    }

    @Override public boolean generator(Object generator) {
        Snapshot current = snapshot;
        if (current.producers().isEmpty()) return false;
        try {
            Position at = position(objectSquare.invoke(generator));
            Network network = at == null ? null : current.producers().get(at);
            if (network == null) return false;
            // A generator in a network powers no square around it and lists nothing as powered.
            ((Map<?, ?>)itemsPowered.get(generator)).clear();
            Object chunk = squareChunk.get(objectSquare.invoke(generator)), cells = cell();
            if (chunk != null && cells != null) {
                int range = chunkRange.getInt(null), wx = chunkX.getInt(chunk), wy = chunkY.getInt(chunk);
                for (int dx = -range; dx <= range; dx++)
                    for (int dy = -range; dy <= range; dy++) {
                        Object near = getChunk.invoke(cells, wx + dx, wy + dy);
                        if (near != null) removeGeneratorPos.invoke(near, at.x(), at.y(), at.z());
                    }
            }
            setUsing.invoke(generator, consumption(network, at));
            changed = true;
            return true;
        } catch (InvocationTargetException failure) {
            throw new IllegalStateException(failure.getCause());
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException(failure);
        }
    }

    @Override public void consumerChanged(Object square) {
        if (square == null) return;
        Snapshot current = snapshot;
        try {
            int x = squareX.getInt(square), y = squareY.getInt(square), z = squareZ.getInt(square);
            for (Network network : current.withArea()) {
                // A light switch on a south or east wall stands on the square beyond its room.
                Area area = network.area;
                boolean near = false;
                for (int dx = -1; dx <= 1 && !near; dx++)
                    for (int dy = -1; dy <= 1 && !near; dy++) near = area != null && area.contains(x + dx, y + dy, z);
                if (near) { network.loadChanged = true; changed = true; }
            }
            List<Rule> rules = current.rules().get(new Position(x, y, z));
            if (rules != null) for (Rule rule : rules) if (rule.included()) { rule.network().loadChanged = true; changed = true; }
        } catch (IllegalAccessException failure) {
            throw new IllegalStateException(failure);
        }
    }

    // The game's thread.

    /** Once a frame: works the networks out again once a second, or when something changed. */
    void frame(Object cells) throws ReflectiveOperationException {
        long now = System.nanoTime();
        boolean due = now - refreshedAt >= REFRESH_NANOS;
        if (!due && !changed) return;
        changed = false;
        if (due) refreshedAt = now;
        var supplyChanged = new ArrayList<Network>();
        for (Network network : networks.values()) {
            resolve(network);
            Position inUse = null;
            for (Position producer : network.producers) {
                Object generator = generatorAt(cells, producer);
                if (generator != null) network.runnable.put(producer, runnable(generator));
                else if (square.invoke(cells, producer.x(), producer.y(), producer.z()) != null) network.runnable.put(producer, false);
                if (inUse == null && network.runnable.getOrDefault(producer, false)) inUse = producer;
            }
            if ((inUse == null) != (network.inUse == null)) supplyChanged.add(network);
            network.inUse = inUse;
            if (network.loadChanged || !network.loadComplete && now - network.loadAt >= INCOMPLETE_LOAD_NANOS) load(network, cells, now);
        }
        Snapshot before = snapshot;
        snapshot = snapshot();
        // Producers that joined or left a network: the API, or the game, works out their surroundings again.
        var regrouped = new HashSet<Position>(before.producers().keySet());
        regrouped.addAll(snapshot.producers().keySet());
        regrouped.removeIf(at -> before.producers().get(at) != null && snapshot.producers().get(at) != null);
        for (Position at : regrouped) {
            Object generator = generatorAt(cells, at);
            if (generator != null) surroundings.invoke(generator);
        }
        // The producer in use carries the load; the others only their own.
        for (Network network : networks.values())
            for (Position producer : network.producers) {
                Object generator = generatorAt(cells, producer);
                float consumption = consumption(network, producer);
                if (generator != null && using.getFloat(generator) != consumption) setUsing.invoke(generator, consumption);
            }
        // The objects that gained or lost power update what follows from it (a fridge's hum, a lamp's light).
        for (Network network : supplyChanged)
            for (var consumer : consumers(network, new boolean[1])) checkElectricity.invoke(consumer.object());
    }

    /** What a producer of the network burns: its own base consumption, and the network's load when it carries it. */
    private float consumption(Network network, Position producer) throws IllegalAccessException {
        return basePower.getFloat(null) + (producer.equals(network.inUse) ? network.load : 0f);
    }

    /** The member buildings as the map data has them now; a player-built one is made again when its walls change. */
    private void resolve(Network network) throws ReflectiveOperationException {
        var found = new ArrayList<Buildings.Building>();
        for (Position at : network.buildings) {
            var building = buildings.buildingAt(at.x(), at.y(), at.z());
            if (building != null && found.stream().noneMatch(other -> other.def() == building.def())) found.add(building);
        }
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
     * The network's load: what its consumers use, the ones on squares that are not loaded as they used it when last
     * seen loaded.
     */
    private void load(Network network, Object cells, long now) throws ReflectiveOperationException {
        boolean[] complete = { true };
        var next = new LinkedHashMap<Thing, Float>();
        for (var consumer : consumers(network, complete))
            next.put(new Thing(new Position(consumer.x(), consumer.y(), consumer.z()), buildings.sprite(consumer.object())),
                buildings.consumption(consumer.object()));
        for (var last : network.consumption.entrySet()) {
            Position at = last.getKey().at();
            if (!next.containsKey(last.getKey()) && square.invoke(cells, at.x(), at.y(), at.z()) == null) next.put(last.getKey(), last.getValue());
        }
        float load = 0;
        for (float value : next.values()) load += value;
        network.consumption = next;
        network.load = load;
        network.loadComplete = complete[0];
        network.loadAt = now;
        network.loadChanged = false;
    }

    /**
     * The network's consumers on loaded squares: the objects of its buildings that the game could power from a
     * generator, but those excluded, and the objects added on their own.
     */
    List<Buildings.Found> consumers(Network network, boolean[] complete) throws ReflectiveOperationException {
        var result = new ArrayList<Buildings.Found>();
        var seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        for (var building : network.resolved)
            for (var found : buildings.scan(building, POWER, complete))
                if (!excluded(network, found.object()) && seen.add(found.object())) result.add(found);
        Object cells = cell();
        for (Thing thing : network.included) {
            Object loaded = cells == null ? null : square.invoke(cells, thing.at().x(), thing.at().y(), thing.at().z());
            if (loaded == null) { complete[0] = false; continue; }
            for (Object object : buildings.objectsOn(loaded)) {
                if (!thing.sprite().equals(buildings.sprite(object))) continue;
                var found = buildings.classify(object, POWER, thing.at().x(), thing.at().y(), thing.at().z(), null);
                if (found != null && seen.add(object)) result.add(found);
            }
        }
        return result;
    }

    /** Whether the network excludes the object: one of its squares, for an object that covers several. */
    private boolean excluded(Network network, Object object) throws ReflectiveOperationException {
        if (network.excluded.isEmpty()) return false;
        for (Object part : parts(object)) {
            Thing thing = thing(part);
            if (thing != null && network.excluded.contains(thing)) return true;
        }
        return false;
    }

    private Snapshot snapshot() {
        var supplied = new ArrayList<Area>();
        var withArea = new ArrayList<Network>();
        var producers = new HashMap<Position, Network>();
        var rules = new HashMap<Position, List<Rule>>();
        for (Network network : networks.values()) {
            boolean on = network.inUse != null;
            if (network.area != null) { withArea.add(network); if (on) supplied.add(network.area); }
            for (Position producer : network.producers) producers.put(producer, network);
            for (Thing thing : network.excluded) rules.computeIfAbsent(thing.at(), at -> new ArrayList<>()).add(new Rule(thing.sprite(), false, on, network));
            for (Thing thing : network.included) rules.computeIfAbsent(thing.at(), at -> new ArrayList<>()).add(new Rule(thing.sprite(), true, on, network));
        }
        rules.replaceAll((at, list) -> List.copyOf(list));
        return new Snapshot(supplied.toArray(Area[]::new), List.copyOf(withArea), Map.copyOf(producers), Map.copyOf(rules));
    }

    private Object generatorAt(Object cells, Position at) throws ReflectiveOperationException {
        Object loaded = cells == null ? null : square.invoke(cells, at.x(), at.y(), at.z());
        return loaded == null ? null : generatorOf.invoke(loaded);
    }

    /** A generator can run: switched on, with fuel, not broken. */
    private boolean runnable(Object generator) throws ReflectiveOperationException {
        return (boolean)activated.invoke(generator) && (float)fuel.invoke(generator) > 0 && (int)condition.invoke(generator) > 0;
    }

    /** The object and, for one that covers several squares, its other parts. */
    private List<Object> parts(Object object) throws ReflectiveOperationException {
        if (!(boolean)hasGrid.invoke(object)) return List.of(object);
        @SuppressWarnings("unchecked")
        var parts = (List<Object>)gridObjects.invoke(object, new ArrayList<>());
        return parts.isEmpty() ? List.of(object) : parts;
    }

    private Thing thing(Object object) throws ReflectiveOperationException {
        Position at = position(objectSquare.invoke(object));
        String sprite = at == null ? null : buildings.sprite(object);
        return sprite == null ? null : new Thing(at, sprite);
    }

    private Position position(Object loaded) throws IllegalAccessException {
        return loaded == null ? null : new Position(squareX.getInt(loaded), squareY.getInt(loaded), squareZ.getInt(loaded));
    }
}
