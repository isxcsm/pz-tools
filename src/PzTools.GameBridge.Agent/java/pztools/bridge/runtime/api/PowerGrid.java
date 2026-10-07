package pztools.bridge.runtime.api;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import pztools.bridge.ApiHooks;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Seen;
import pztools.bridge.runtime.api.Network.Settled;
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

    /** Raised to Lua mods when a network's supply, producer in use or load changes: its id, what, and the hour. */
    static final String EVENT = "OnPZToolsNetworkChange";

    private record Change(String id, String what, double hour) { }

    /** An object rule of a network at one square. */
    private record Rule(String sprite, boolean included, boolean supplied, Network network) { }

    /**
     * What the hooks read. {@code supplied} holds the areas of the networks that have supply now, {@code rooms} the
     * ids of their buildings' rooms.
     */
    private record Snapshot(Area[] supplied, Set<Long> rooms, List<Network> withArea, Map<Position, Network> producers,
            Map<Position, List<Rule>> rules) {
        static final Snapshot EMPTY = new Snapshot(new Area[0], Set.of(), List.of(), Map.of(), Map.of());
    }

    private final Buildings buildings;
    private final Map<String, Network> networks;
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change and by the hooks; the next frame works the networks out again.
    private volatile boolean changed = true;
    // The producers the last frame left in networks: one that joins or leaves gets its surroundings worked out again.
    private Set<Position> grouped = Set.of();
    // In a frame: the hour each network's producer in use started or stopped, when it did.
    private final Map<Network, Double> supplyHours = new HashMap<>();
    private long refreshedAt = Long.MIN_VALUE;

    private final Method cell, getChunk, square, generatorOf, objectSquare, checkElectricity, hasGrid, gridObjects;
    private final Field squareX, squareY, squareZ, squareChunk, chunkX, chunkY;
    private final Method removeGeneratorPos, activated, fuel, condition, setUsing, surroundings, perHour, setActivated;
    private final Method gameTime, worldHours, addEvent, triggerEvent, optionValue;
    private final Field sandbox, fuelRate;
    private final Field lastHour;
    // The getter gives the consumption times the sandbox's fuel rate; the field is what setTotalPowerUsing set.
    private final Field itemsPowered, using, chunkRange, basePower, worldInstance;
    private final Method containerPowered, switchPowered, devicePowered, battery, deviceParent;
    private final Method squarePowered, containerParent, containerSquare;
    private final Field switchRoom;
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
        perHour = generator.getMethod("getTotalPowerUsing");
        setActivated = generator.getMethod("setActivated", boolean.class);
        lastHour = accessible(generator.getDeclaredField("lastHour"));
        Class<?> time = type(loader, "zombie.GameTime");
        gameTime = time.getMethod("getInstance");
        worldHours = time.getMethod("getWorldAgeHours");
        Class<?> options = type(loader, "zombie.SandboxOptions");
        sandbox = options.getField("instance");
        fuelRate = options.getField("generatorFuelConsumption");
        optionValue = fuelRate.getType().getMethod("getValue");
        Class<?> events = type(loader, "zombie.Lua.LuaEventManager");
        addEvent = events.getMethod("AddEvent", String.class);
        triggerEvent = events.getMethod("triggerEvent", String.class, Object.class, Object.class, Object.class);
        itemsPowered = accessible(generator.getDeclaredField("itemsPowered"));
        chunkRange = accessible(generator.getDeclaredField("generatorChunkRange"));
        basePower = accessible(generator.getDeclaredField("GeneratorBasePowerConsumption"));
        containerPowered = type(loader, "zombie.inventory.ItemContainer").getMethod("isObjectPowered", objectType, boolean.class);
        switchPowered = accessible(lightSwitch.getDeclaredMethod("hasElectricityAround"));
        devicePowered = device.getMethod("canBePoweredHere");
        squarePowered = squareType.getMethod("haveElectricity");
        Class<?> container = type(loader, "zombie.inventory.ItemContainer");
        containerParent = container.getMethod("getParent");
        containerSquare = container.getMethod("getSourceGrid");
        switchRoom = lightSwitch.getField("roomId");
        battery = device.getMethod("getIsBatteryPowered");
        deviceParent = device.getMethod("getParent");
        worldInstance = worldType.getField("instance");
    }

    private static Class<?> type(ClassLoader loader, String name) throws ClassNotFoundException {
        return Class.forName(name, false, loader);
    }

    private static <T extends AccessibleObject> T accessible(T member) { member.setAccessible(true); return member; }

    /** Makes the networks' event known to the game's Lua (once per game; a Lua environment made later gets it too). */
    void addEvent() throws ReflectiveOperationException { addEvent.invoke(null, EVENT); }

    /**
     * A definition changed: the hooks know the producers at once (a world's generators make up for the hours the world
     * was away as they first update, which can come before the next frame), and the next frame works the rest out.
     */
    void changed() throws ReflectiveOperationException {
        snapshot = snapshot();
        changed = true;
    }

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
        if (current.rules().isEmpty() && (kind != ApiHooks.ROOM_LIGHT || current.rooms().isEmpty())) return vanilla;
        boolean[] pure = PURE.get();
        if (pure[0]) return vanilla;
        try {
            Object target = object;
            if (kind == ApiHooks.DEVICE) {
                if ((boolean)battery.invoke(object)) return vanilla;
                target = deviceParent.invoke(object);
                if (!objectType.isInstance(target)) return vanilla;
            } else if (kind == ApiHooks.FOOD) {
                target = containerParent.invoke(object);
                if (!objectType.isInstance(target)) return vanilla;
            }
            boolean excluded = false;
            for (Object part : current.rules().isEmpty() ? List.of() : parts(target)) {
                Thing thing = thing(part);
                List<Rule> rules = thing == null ? null : current.rules().get(thing.at());
                if (rules == null) continue;
                for (Rule rule : rules) {
                    if (!rule.sprite().equals(thing.sprite())) continue;
                    if (rule.included() && rule.supplied()) return true;
                    if (!rule.included()) excluded = true;
                }
            }
            // A switch powers its room's light when a network supplies that room, wherever the switch stands: one on a
            // south or east wall stands on the square beyond, outside the building.
            if (!excluded) return vanilla || kind == ApiHooks.ROOM_LIGHT && current.rooms().contains(switchRoom.getLong(object));
            if (!vanilla) return false;
            // The game said yes, perhaps because a network powers the square: ask it again without the networks.
            pure[0] = true;
            try {
                return switch (kind) {
                    case ApiHooks.APPLIANCE -> (boolean)containerPowered.invoke(null, object, true);
                    case ApiHooks.LIGHT_SWITCH -> (boolean)switchPowered.invoke(object);
                    case ApiHooks.DEVICE -> (boolean)devicePowered.invoke(object);
                    case ApiHooks.ROOM_LIGHT -> squarePowered(objectSquare.invoke(object));
                    default -> squarePowered(containerSquare.invoke(object));
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

    @Override public void generatorUpdate(Object generator) {
        Snapshot current = snapshot;
        if (current.producers().isEmpty()) return;
        try {
            Position at = position(objectSquare.invoke(generator));
            Network network = at == null ? null : current.producers().get(at);
            if (network == null || !(boolean)activated.invoke(generator)) return;
            // The getter gives what it burns an hour: its consumption times the sandbox's fuel rate.
            network.settled.put(at, new Settled(lastHour.getInt(generator), (float)fuel.invoke(generator), (float)perHour.invoke(generator)));
            // Running before the API knew which producer was in use: the world was just loaded, or the player switched it on.
            if (network.inUse == null) network.adopted = at;
        } catch (InvocationTargetException failure) {
            throw new IllegalStateException(failure.getCause());
        } catch (ReflectiveOperationException failure) {
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
        var changes = new ArrayList<Change>();
        double hours = (double)worldHours.invoke(gameTime.invoke(null));
        var fresh = new HashSet<Network>();
        supplyHours.clear();
        var totals = new HashMap<Network, Float>();
        for (Network network : networks.values()) {
            totals.put(network, network.total);
            resolve(network);
            if (network.parent == null) producers(network, cells, hours, changes);
            else network.inUse = null;
            if (network.loadChanged || !network.loadComplete && now - network.loadAt >= INCOMPLETE_LOAD_NANOS) {
                if (network.loadAt == 0) fresh.add(network);
                load(network, cells, now);
            }
        }
        // A child has supply while its parent has, and its parent carries its load.
        for (Network network : networks.values()) {
            Network root = root(network);
            boolean supplied = root != null && root.inUse != null;
            if (supplied != network.supplied) {
                network.supplied = supplied;
                supplyChanged.add(network);
                // When the producer in use started or stopped; for a child, when its parent's did.
                network.suppliedAt = supplyHours.getOrDefault(root, hours);
                changes.add(new Change(network.id, "supply", network.suppliedAt));
            }
            network.total = total(network);
        }
        for (Network network : networks.values())
            if (!fresh.contains(network) && Math.abs(network.total - totals.get(network)) > 1e-6f)
                changes.add(new Change(network.id, "load", hours));
        snapshot = snapshot();
        // Producers that joined or left a network: the API, or the game, works out their surroundings again.
        Set<Position> producersNow = snapshot.producers().keySet(), producersBefore = grouped;
        var regrouped = new HashSet<Position>(producersBefore);
        regrouped.addAll(producersNow);
        regrouped.removeIf(at -> producersBefore.contains(at) && producersNow.contains(at));
        grouped = Set.copyOf(producersNow);
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
        // Last, so that a mod that asks for the state then gets it.
        for (Change change : changes) triggerEvent.invoke(null, EVENT, change.id(), change.what(), change.hour());
    }

    /**
     * Which producer carries the network under {@code "sequential"}: one runs at a time. The one the player switched on
     * last carries it, and the API switches the others off. When the one in use runs out of fuel or breaks, the API
     * switches on the first other producer, in order, that can run, from the hour the first stopped: the game then
     * burns the hours since, as it does for a generator whose square was not loaded. Switched off by the player, the
     * one in use stops the network. A producer whose square is not loaded counts as last seen, and the one in use as
     * stopped once its fuel would have run out.
     */
    private void producers(Network network, Object cells, double hours, List<Change> changes) throws ReflectiveOperationException {
        var generators = new HashMap<Position, Object>();
        var loaded = new HashSet<Position>();
        var newcomers = new ArrayList<Position>();
        for (Position producer : network.producers) {
            Object generator = generatorAt(cells, producer);
            if (generator == null && square.invoke(cells, producer.x(), producer.y(), producer.z()) == null) continue;
            loaded.add(producer);
            // A loaded square without the generator: it was taken away.
            Seen now = generator == null ? new Seen(false, 0, 0)
                : new Seen((boolean)activated.invoke(generator), (float)fuel.invoke(generator), (int)condition.invoke(generator));
            Seen last = network.seen.put(producer, now);
            if (generator != null) generators.put(producer, generator);
            if (now.activated() && last != null && !last.activated()) newcomers.add(producer);
        }
        // The one in use as the API knew it, or one the game ran before the API knew which (see generatorUpdate).
        Position before = network.inUse, current = before != null ? before : network.adopted, inUse = current;
        network.adopted = null;
        double at = hours;
        if (current != null && network.seen.containsKey(current)) {
            Seen state = network.seen.get(current);
            Settled settled = network.settled.get(current);
            if (loaded.contains(current)) {
                if (!state.activated()) {
                    if (state.canRun()) inUse = null;
                    else {
                        at = settled == null ? hours : Math.min(hours, settled.end());
                        inUse = next(network, current, generators);
                    }
                }
            } else if (settled != null && settled.end() <= hours) {
                at = settled.end();
                inUse = next(network, current, generators);
            }
        }
        if (!newcomers.isEmpty() && !newcomers.contains(inUse)) { inUse = newcomers.get(0); at = hours; }
        else if (inUse == null && before == null)
            for (Position producer : network.producers) {
                Seen state = network.seen.get(producer);
                if (loaded.contains(producer) && state.activated()) { inUse = producer; break; }
            }
        network.inUse = inUse;
        for (var entry : generators.entrySet()) {
            Position producer = entry.getKey();
            Seen state = network.seen.get(producer);
            if (producer.equals(inUse) && !state.activated()) {
                // Started by the API, from the hour the last one stopped.
                setActivated.invoke(entry.getValue(), true);
                lastHour.setInt(entry.getValue(), (int)Math.floor(at));
                network.seen.put(producer, new Seen(true, state.fuel(), state.condition()));
            } else if (!producer.equals(inUse) && state.activated()) {
                setActivated.invoke(entry.getValue(), false);
                network.seen.put(producer, new Seen(false, state.fuel(), state.condition()));
            }
        }
        if ((before == null) != (inUse == null)) supplyHours.put(network, at);
        else if (inUse != null && !inUse.equals(before)) changes.add(new Change(network.id, "producer", at));
    }

    /** The first producer of the network, in order, that is loaded and can run, other than the one that stopped. */
    private static Position next(Network network, Position stopped, Map<Position, Object> generators) {
        for (Position producer : network.producers)
            if (!producer.equals(stopped) && generators.containsKey(producer) && network.seen.get(producer).canRun()) return producer;
        return null;
    }

    /**
     * What a producer of the network burns: its own base consumption, and the load of the network and its children when
     * it carries it.
     */
    private float consumption(Network network, Position producer) throws IllegalAccessException {
        return basePower.getFloat(null) + (producer.equals(network.inUse) ? network.total : 0f);
    }

    /** The network at the top of a child's parents; null when a parent is missing. */
    Network root(Network network) {
        for (int depth = 0; network != null && depth <= networks.size(); depth++) {
            if (network.parent == null) return network;
            network = networks.get(network.parent);
        }
        return null;
    }

    /** The load of the network and of its children, theirs included. Networks form a tree (see Networks.setParent). */
    private float total(Network network) {
        float total = network.load;
        for (Network child : networks.values()) if (network.id.equals(child.parent)) total += total(child);
        return total;
    }

    /**
     * How long the network's supply lasts at its load now: the fuel of its producer in use and of those that can take
     * over, as last seen, over what the one in use would burn an hour. Null without supply or without consumption.
     */
    Double hoursLeft(Network network) throws ReflectiveOperationException {
        Network root = root(network);
        if (root == null || root.inUse == null) return null;
        double perHour = (basePower.getFloat(null) + root.total) * (double)optionValue.invoke(fuelRate.get(sandbox.get(null)));
        if (perHour <= 0) return null;
        double fuel = 0;
        for (Position producer : root.producers) {
            Seen state = root.seen.get(producer);
            if (state != null && (producer.equals(root.inUse) || state.canRun())) fuel += state.fuel();
        }
        return fuel / perHour;
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

    private boolean squarePowered(Object square) throws ReflectiveOperationException {
        return square != null && (boolean)squarePowered.invoke(square);
    }

    private Snapshot snapshot() throws ReflectiveOperationException {
        var supplied = new ArrayList<Area>();
        var rooms = new HashSet<Long>();
        var withArea = new ArrayList<Network>();
        var producers = new HashMap<Position, Network>();
        var rules = new HashMap<Position, List<Rule>>();
        for (Network network : networks.values()) {
            boolean on = network.supplied;
            if (network.area != null) { withArea.add(network); if (on) supplied.add(network.area); }
            if (on) for (var building : network.resolved) for (Object room : building.rooms()) rooms.add(buildings.roomId(room));
            for (Position producer : network.producers) producers.put(producer, network);
            for (Thing thing : network.excluded) rules.computeIfAbsent(thing.at(), at -> new ArrayList<>()).add(new Rule(thing.sprite(), false, on, network));
            for (Thing thing : network.included) rules.computeIfAbsent(thing.at(), at -> new ArrayList<>()).add(new Rule(thing.sprite(), true, on, network));
        }
        rules.replaceAll((at, list) -> List.copyOf(list));
        return new Snapshot(supplied.toArray(Area[]::new), Set.copyOf(rooms), List.copyOf(withArea), Map.copyOf(producers), Map.copyOf(rules));
    }

    private Object generatorAt(Object cells, Position at) throws ReflectiveOperationException {
        Object loaded = cells == null ? null : square.invoke(cells, at.x(), at.y(), at.z());
        return loaded == null ? null : generatorOf.invoke(loaded);
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
