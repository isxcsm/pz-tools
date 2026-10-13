package pzext.api;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.function.IntUnaryOperator;
import pzext.boot.Hooks;
import pzext.api.Network.Away;
import pzext.api.Network.Position;
import pzext.api.Network.Producer;
import pzext.api.Network.Seen;
import pzext.api.Network.Source;
import pzext.api.Network.Settled;
import pzext.api.Network.Thing;
import pzext.api.Members.Area;

/**
 * Runs the power networks (docs/design.md, "Power"): answers the game's power questions through the
 * hooks, keeps the generators of a network from powering their surroundings, and works out each network's supply and
 * load. The hooks read an immutable snapshot, so a question asked on any thread costs a lookup; everything else runs on
 * the game's thread, once a second or when something changed.
 */
final class PowerGrid implements Hooks.Power {
    // The supply changes a network keeps for food: a bound on memory, far more than a fridge sees between two ageings.
    private static final int MAX_HISTORY = 256;
    // Set while the game's own answer is asked again for an excluded object: the networks then give no square power.
    private static final ThreadLocal<boolean[]> PURE = ThreadLocal.withInitial(() -> new boolean[1]);

    static final String UTILITY = "power";
    /** {@code OnPZExtGeneratorPower(generator, on, after)}: a generator is switched; see generatorSwitch. */
    static final String GENERATOR_EVENT = "OnPZExtGeneratorPower";
    /**
     * In the modData of a generator out of service (see Network.outOfService), {@code true}: the API saw it switched off
     * by hand. The world saves it with the generator, as it saves the generator's switch, and the game moves neither to
     * the item a picked-up generator becomes. Taken off when the generator is seen running.
     */
    static final String OUT_OF_SERVICE = "PZExtOutOfService";
    /**
     * In the modData of the generator to start first when its network, switched off, is switched on again (see
     * Network.resume): its {@code lastHour} when it was marked. The game changes {@code lastHour} only while the
     * generator runs, so a mark whose hour is not the generator's is from before it ran again, and counts for nothing.
     */
    static final String RESUME = "PZExtResume";
    /**
     * In the modData of a generator of a network that the API saw running, {@code true}; taken off when the API sees it
     * stop or switches it off. Off when the API first sees it, a generator that still has it and can run was switched
     * off where the API did not see it (the game started without it, or before the next frame): by hand.
     */
    static final String RUNNING = "PZExtRunning";
    private static final String[] MARKS = { OUT_OF_SERVICE, RESUME, RUNNING };
    /**
     * The game's breakdown of a running generator as its hourly update ends (IsoGenerator.update): at this condition or
     * below, fire one hour in {@link #FIRE_ONE_IN}, else an explosion one in {@link #EXPLOSION_ONE_IN}; its condition
     * wears by 1 or 2 one hour in its item's ConditionLowerChanceOneIn, {@link #WEAR_ONE_IN} for an item without it.
     */
    static final int BREAKDOWN_CONDITION = 20, FIRE_ONE_IN = 10, EXPLOSION_ONE_IN = 20, WEAR_ONE_IN = 30;
    /** A number from 0 up to the bound, for the rolls of generators that run away (see away); a test sets its own. */
    static IntUnaryOperator dice = bound -> ThreadLocalRandom.current().nextInt(bound);

    private record Change(String id, String what, double hour) { }

    /** Changes of one yes-or-no over the hours: when it became true or false, and what it was before the first. */
    record Track(double[] hours, boolean[] values, boolean before) {
        static Track of(NavigableMap<Double, Boolean> changes, boolean before) {
            double[] hours = new double[changes.size()];
            boolean[] values = new boolean[hours.length];
            int index = 0;
            for (var change : changes.entrySet()) { hours[index] = change.getKey(); values[index++] = change.getValue(); }
            return new Track(hours, values, before);
        }

        boolean at(double hour) {
            boolean result = before;
            for (int index = 0; index < hours.length && hours[index] <= hour; index++) result = values[index];
            return result;
        }
    }

    /**
     * A network's supply over the hours, as the hooks read it: the supply of the network at the top of its parents
     * (see Network.history), while it and each parent between were switched on (Network.switches).
     */
    record History(List<Track> tracks) {
        static History of(Network root, List<Network> chain) {
            var tracks = new ArrayList<Track>();
            tracks.add(Track.of(root.history, root.suppliedBefore));
            for (Network network : chain)
                if (!network.switches.isEmpty() || !network.enabledBefore) tracks.add(Track.of(network.switches, network.enabledBefore));
            return new History(List.copyOf(tracks));
        }

        /**
         * How many of the hours from {@code from} to {@code to} were chilled: the network had supply, or the grid had
         * power (before {@code gridEnd}).
         */
        double chilled(double from, double to, double gridEnd) {
            var cuts = new TreeSet<Double>(List.of(from, to));
            for (Track track : tracks) for (double hour : track.hours()) if (hour > from && hour < to) cuts.add(hour);
            if (gridEnd > from && gridEnd < to) cuts.add(gridEnd);
            double result = 0, start = from;
            for (double end : cuts.tailSet(from, false)) {
                double middle = (start + end) / 2;
                if (middle < gridEnd || at(middle)) result += end - start;
                start = end;
            }
            return result;
        }

        private boolean at(double hour) {
            for (Track track : tracks) if (!track.at(hour)) return false;
            return true;
        }
    }

    /**
     * What the hooks read. {@code supplied} holds the areas of the networks that have supply now, {@code rooms} the
     * ids of their buildings' rooms, sorted; each object rule says whether its network has supply.
     */
    private record Snapshot(Area[] supplied, long[] rooms, List<Network> withArea, Map<Position, Network> producers,
            Rules<Boolean> rules, Map<Network, History> histories) {
        static final Snapshot EMPTY = new Snapshot(new Area[0], new long[0], List.of(), Map.of(), Rules.none(), Map.of());

        /** Whether a supplied network takes the room of that id. */
        boolean lit(long room) { return Arrays.binarySearch(rooms, room) >= 0; }
    }

    private final Game game;
    private final Networks networks;
    private final Members members;
    private final Buildings buildings;
    private final Cadence cadence = new Cadence();
    // The generator being switched now (see generatorSwitch): the game's own switch of it runs without the hook.
    private Object switching;
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change, made on the thread that changed it; see current().
    private volatile boolean stale;
    // Set by a definition change and a history begun: the next frame makes the snapshot again (see frame).
    private volatile boolean rebuild = true;
    private volatile Thread changer;
    // The producers the last frame left in networks: one that joins or leaves gets its surroundings worked out again.
    private Set<Position> grouped = Set.of();
    // In a frame: the hour each network's producer in use started or stopped, when it did.
    private final Map<Network, Double> supplyHours = new HashMap<>();
    // Squares whose generators left the producers (see left), and generators the game switched on in no network (see
    // generator): the next frame takes the marks off those that are in no network, so that marks are on network
    // generators alone. The hook may come on another thread.
    private final Set<Position> leftSquares = new HashSet<>();
    private final Queue<Object> loose = new java.util.concurrent.ConcurrentLinkedQueue<>();
    private final Field client;

    private final Method getChunk, generatorOf, checkElectricity;
    private final Field squareChunk, chunkX, chunkY;
    private final Method removeGeneratorPos, activated, fuel, condition, setUsing, surroundings, perHour, setActivated;
    private final Method setFuel, setCondition;
    // A generator's item and its ConditionLowerChanceOneIn; null for a game that has them elsewhere (WEAR_ONE_IN then).
    private final Method itemType, scriptItem, lowerChance;
    private final Field scripts;
    private final Method optionValue, elecShut;
    private final Method outermost, frozen, fridgeFactor, lastAged, isFridge, isFreezer;
    private final Field sandbox, fuelRate;
    private final Field lastHour;
    // The getter gives the consumption times the sandbox's fuel rate; the field is what setTotalPowerUsing set.
    private final Field itemsPowered, using, chunkRange, basePower;
    private final Method containerPowered, switchPowered, devicePowered, battery, deviceParent;
    private final Method squarePowered, containerParent, containerSquare;
    private final Kahlua lua;
    // IsoObject.hasModData, which reads an object's modData without making it; null for a game without it.
    private final Method modData, hasModData;

    PowerGrid(ClassLoader loader, Game game, Networks networks, Members members, Buildings buildings, Kahlua lua)
            throws ReflectiveOperationException {
        this.game = game;
        this.networks = networks;
        this.members = members;
        this.buildings = buildings;
        this.lua = lua;
        modData = game.objectType.getMethod("getModData");
        client = Game.type(loader, "zombie.network.GameClient").getField("client");
        Method has;
        try { has = game.objectType.getMethod("hasModData"); }
        catch (NoSuchMethodException none) { has = null; }
        hasModData = has;
        Class<?> squareType = Game.type(loader, "zombie.iso.IsoGridSquare"), chunkType = Game.type(loader, "zombie.iso.IsoChunk");
        Class<?> generator = Game.type(loader, "zombie.iso.objects.IsoGenerator");
        Class<?> device = Game.type(loader, "zombie.radio.devices.DeviceData");
        Class<?> container = game.container;
        getChunk = Game.type(loader, "zombie.iso.IsoCell").getMethod("getChunk", int.class, int.class);
        generatorOf = squareType.getMethod("getGenerator");
        squareChunk = squareType.getField("chunk");
        chunkX = chunkType.getField("wx"); chunkY = chunkType.getField("wy");
        removeGeneratorPos = chunkType.getMethod("removeGeneratorPos", int.class, int.class, int.class);
        checkElectricity = game.objectType.getMethod("checkHaveElectricity");
        activated = generator.getMethod("isActivated");
        fuel = generator.getMethod("getFuel");
        condition = generator.getMethod("getCondition");
        setUsing = generator.getMethod("setTotalPowerUsing", float.class);
        using = Game.accessible(generator.getDeclaredField("totalPowerUsing"));
        surroundings = generator.getMethod("setSurroundingElectricity");
        perHour = generator.getMethod("getTotalPowerUsing");
        setActivated = generator.getMethod("setActivated", boolean.class);
        setFuel = generator.getMethod("setFuel", float.class);
        setCondition = generator.getMethod("setCondition", int.class);
        Method type = null, item = null, chance = null;
        Field manager = null;
        try {
            type = generator.getMethod("getGeneratorItemType");
            Class<?> scriptManager = Game.type(loader, "zombie.scripting.ScriptManager");
            manager = scriptManager.getField("instance");
            item = scriptManager.getMethod("getItem", String.class);
            chance = item.getReturnType().getMethod("getConditionLowerChance");
        } catch (ReflectiveOperationException none) {
            type = null;
        }
        itemType = type; scriptItem = item; lowerChance = chance; scripts = manager;
        lastHour = Game.accessible(generator.getDeclaredField("lastHour"));
        Class<?> options = Game.type(loader, "zombie.SandboxOptions");
        sandbox = options.getField("instance");
        fuelRate = options.getField("generatorFuelConsumption");
        optionValue = fuelRate.getType().getMethod("getValue");
        elecShut = options.getMethod("getElecShutModifier");
        Class<?> food = Game.type(loader, "zombie.inventory.types.Food");
        outermost = food.getMethod("getOutermostContainer");
        frozen = food.getMethod("isFrozen");
        fridgeFactor = Game.accessible(food.getDeclaredMethod("getFridgeFactor"));
        lastAged = food.getMethod("getLastAged");
        itemsPowered = Game.accessible(generator.getDeclaredField("itemsPowered"));
        chunkRange = Game.accessible(generator.getDeclaredField("generatorChunkRange"));
        basePower = Game.accessible(generator.getDeclaredField("GeneratorBasePowerConsumption"));
        containerPowered = container.getMethod("isObjectPowered", game.objectType, boolean.class);
        switchPowered = Game.accessible(game.lightSwitch.getDeclaredMethod("hasElectricityAround"));
        devicePowered = device.getMethod("canBePoweredHere");
        squarePowered = squareType.getMethod("haveElectricity");
        containerParent = container.getMethod("getParent");
        containerSquare = container.getMethod("getSourceGrid");
        isFridge = container.getMethod("isFridge");
        isFreezer = container.getMethod("isFreezer");
        battery = device.getMethod("getIsBatteryPowered");
        deviceParent = device.getMethod("getParent");
    }

    /**
     * A definition changed: the hooks know the definitions at once on the thread that changed them, the game's (a world's
     * generators make up for the hours the world was away as they first update, which can come before the next frame),
     * and the next frame works the rest out. Many changes in a row make one snapshot, not one each.
     */
    void changed() {
        changer = Thread.currentThread();
        stale = true;
        rebuild = true;
        cadence.changed();
    }

    /**
     * What the hooks read: made again here after a definition changed, when the question comes on the thread that
     * changed it, which is the one that changes the networks; another thread reads the last one until the next frame.
     */
    private Snapshot current() {
        if (stale && Thread.currentThread() == changer) {
            stale = false;
            try { snapshot = build(); }
            catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
        }
        return snapshot;
    }

    /** The mod switched the network on or off: remembered for food, and worked out again in the next frame. */
    void switched(Network network) throws ReflectiveOperationException {
        network.switches.put(game.hours(), network.enabled);
        while (network.switches.size() > MAX_HISTORY) network.enabledBefore = network.switches.pollFirstEntry().getValue();
        network.loadChanged = true;
    }

    // The hooks.

    /** A square of a supplied building's rooms, or of its shell (its roof, the squares against it; see Members.Area). */
    @Override public boolean square(int x, int y, int z) {
        for (Area area : current().supplied()) if (area.contains(x, y, z) || area.shelters(x, y, z)) return !PURE.get()[0];
        return false;
    }

    @Override public boolean object(boolean vanilla, Object object, int kind, boolean generators) {
        if (!generators || object == null) return vanilla;
        Snapshot current = current();
        // The game said no while a network has supply: a network may add to it. Its yes stands but for an exclusion.
        boolean asked = !vanilla && current.supplied().length > 0;
        if (!asked && current.rules().isEmpty()) return vanilla;
        try {
            Object target = target(object, kind);
            if (target == null) return vanilla;
            // Read by index: an iterator would allocate, and nearly every object has no rule.
            var rules = current.rules().naming(target, game, buildings);
            boolean excluded = false;
            for (int index = 0; index < rules.size(); index++) {
                var rule = rules.get(index);
                if (!rule.included()) excluded = true;
                else if (rule.data()) return vanilla || !pure();
            }
            if (!excluded) {
                if (!asked) return vanilla;
                // A switch powers its room's light when a network supplies that room, wherever the switch stands: one on
                // a south or east wall stands on the square beyond, outside the building.
                return (kind == Hooks.ROOM_LIGHT && current.lit(game.switchRoom(object)) || onSuppliedWall(current, target)) && !pure();
            }
            if (!vanilla) return false;
            // The game said yes, perhaps because a network powers the square: ask it again without the networks.
            boolean[] pure = PURE.get();
            if (pure[0]) return vanilla;
            pure[0] = true;
            try {
                return switch (kind) {
                    case Hooks.APPLIANCE -> (boolean)containerPowered.invoke(null, object, true);
                    case Hooks.LIGHT_SWITCH -> (boolean)switchPowered.invoke(object);
                    case Hooks.DEVICE -> (boolean)devicePowered.invoke(object);
                    case Hooks.ROOM_LIGHT -> squarePowered(game.squareOf(object));
                    default -> squarePowered(containerSquare.invoke(object));
                };
            } finally { pure[0] = false; }
        } catch (ReflectiveOperationException failure) {
            throw Game.failed(failure);
        }
    }

    /** Whether the game's own answer is being asked again on this thread, which the networks then leave alone. */
    private static boolean pure() { return PURE.get()[0]; }

    /**
     * The object a question is about: a radio's or television's object (null, the game's answer, for one on batteries),
     * or the object a food container belongs to; null when it is no object of the world.
     */
    private Object target(Object object, int kind) throws ReflectiveOperationException {
        Object target = switch (kind) {
            case Hooks.DEVICE -> (boolean)battery.invoke(object, Game.NONE) ? null : deviceParent.invoke(object, Game.NONE);
            case Hooks.FOOD -> containerParent.invoke(object, Game.NONE);
            default -> object;
        };
        return game.objectType.isInstance(target) ? target : null;
    }

    /**
     * Whether the object, on a square of no room, belongs to a supplied building: it hangs on its outer wall, stands on
     * its roof or against it (see Buildings.home).
     */
    private boolean onSuppliedWall(Snapshot current, Object target) throws ReflectiveOperationException {
        Object square = game.squareOf(target);
        if (square == null) return false;
        int x = game.x(square), y = game.y(square), z = game.z(square);
        int[] step = buildings.homeStep(target, x, y, z);
        if (step == null) return false;
        for (Area area : current.supplied()) if (area.contains(x + step[0], y + step[1], z + step[2])) return true;
        return false;
    }

    @Override public boolean generator(Object generator) {
        Snapshot current = current();
        try {
            Position at = game.at(generator);
            Network network = at == null || current.producers().isEmpty() ? null : current.producers().get(at);
            if (network == null) {
                // In service as a generator of no network: its marks go at the next frame.
                if ((hasModData == null || (boolean)hasModData.invoke(generator, Game.NONE)) && (boolean)activated.invoke(generator))
                    { loose.add(generator); cadence.changed(); }
                return false;
            }
            // A generator in a network powers no square around it and lists nothing as powered.
            ((Map<?, ?>)itemsPowered.get(generator)).clear();
            Object chunk = squareChunk.get(game.squareOf(generator)), cells = game.cell();
            if (chunk != null && cells != null) {
                int range = chunkRange.getInt(null), wx = chunkX.getInt(chunk), wy = chunkY.getInt(chunk);
                for (int dx = -range; dx <= range; dx++)
                    for (int dy = -range; dy <= range; dy++) {
                        Object near = getChunk.invoke(cells, wx + dx, wy + dy);
                        if (near != null) removeGeneratorPos.invoke(near, at.x(), at.y(), at.z());
                    }
            }
            setUsing.invoke(generator, consumption(network, Producer.square(at)));
            cadence.changed();
            return true;
        } catch (ReflectiveOperationException failure) {
            throw Game.failed(failure);
        }
    }

    /**
     * A generator is switched (the game's {@code setActivated}, called only from the game's thread): {@link #GENERATOR_EVENT}
     * before the game switches it, while its squares still have the power they had, and again once they took the new.
     * Switched to what it is already, nothing.
     */
    @Override public boolean generatorSwitch(Object generator, boolean on) {
        if (generator == null || generator == switching) return false;
        Object outer = switching;
        try {
            if ((boolean)activated.invoke(generator) == on) return false;
            // A handler that switches the same generator again gets the game's switch alone.
            switching = generator;
            game.raise(GENERATOR_EVENT, generator, on, false);
            setActivated.invoke(generator, on);
            game.raise(GENERATOR_EVENT, generator, on, true);
            return true;
        } catch (ReflectiveOperationException failure) {
            throw Game.failed(failure);
        } finally {
            switching = outer;
        }
    }

    @Override public void consumerChanged(Object square) {
        if (square == null) return;
        Snapshot current = current();
        try {
            int x = game.x(square), y = game.y(square), z = game.z(square);
            for (Network network : current.withArea()) {
                // A light switch on a south or east wall stands on the square beyond its room.
                Area area = network.area;
                boolean near = false;
                for (int dx = -1; dx <= 1 && !near; dx++)
                    for (int dy = -1; dy <= 1 && !near; dy++) near = area != null && area.contains(x + dx, y + dy, z);
                if (near) { network.loadChanged = true; cadence.changed(); }
            }
            for (var rule : current.rules().at(x, y, z)) if (rule.included()) { rule.network().loadChanged = true; cadence.changed(); }
        } catch (IllegalAccessException failure) {
            throw Game.failed(failure);
        }
    }

    @Override public void generatorUpdate(Object generator) {
        Snapshot current = current();
        if (current.producers().isEmpty()) return;
        try {
            Position at = game.at(generator);
            Network network = at == null ? null : current.producers().get(at);
            if (network == null) return;
            // What it ran while its square was not loaded, before the game burns those hours itself.
            give(network, at, generator, game.hours());
            if (!(boolean)activated.invoke(generator)) return;
            // The getter gives what it burns an hour: its consumption times the sandbox's fuel rate.
            network.settled.put(at, new Settled(lastHour.getInt(generator), (float)fuel.invoke(generator), (float)perHour.invoke(generator),
                wearChance(generator)));
            network.away.remove(at);
            // Running: in service, also when it is switched off again before the next frame (see service).
            network.ran.add(at);
            // Running before the API knew which producer was in use: the world was just loaded, or the player switched it on.
            if (network.inUse == null) network.adopted = Producer.square(at);
        } catch (ReflectiveOperationException failure) {
            throw Game.failed(failure);
        }
    }

    /**
     * The hours food in a fridge or freezer of a network ages over: vanilla counts every hour since it last aged as
     * chilled when the container has power now, and splits them only at the grid's shut-off. For a consumer of a
     * network without the game's own power, they are split also where the network's supply started and stopped.
     */
    @Override public double foodHours(double vanilla, Object food) {
        Snapshot current = current();
        if (current.histories().isEmpty() || food == null) return vanilla;
        boolean[] pure = PURE.get();
        if (pure[0]) return vanilla;
        try {
            Object container = outermost.invoke(food);
            if (container == null || (boolean)frozen.invoke(food) || !(boolean)isFridge.invoke(container) && !(boolean)isFreezer.invoke(container))
                return vanilla;
            Object object = containerParent.invoke(container);
            Network network = game.objectType.isInstance(object) ? consumerOf(current, object) : null;
            History history = network == null ? null : current.histories().get(network);
            if (history == null) return vanilla;
            // The game's own power now (the grid, a generator in range) chills all the hours, as in vanilla.
            pure[0] = true;
            try { if (squarePowered(containerSquare.invoke(container))) return vanilla; }
            finally { pure[0] = false; }
            float now = (float)game.hours(), last = (float)lastAged.invoke(food);
            int shut = (int)elecShut.invoke(sandbox.get(null));
            double chilled = history.chilled(last, now, shut > -1 ? shut * 24.0 : Double.NEGATIVE_INFINITY);
            return chilled * (float)fridgeFactor.invoke(food) + (now - last - chilled);
        } catch (ReflectiveOperationException failure) {
            throw Game.failed(failure);
        }
    }

    /**
     * The network whose consumer the object is, with supply or without: one that added it on its own, or one whose
     * buildings it stands in that did not exclude it.
     */
    private Network consumerOf(Snapshot current, Object object) throws ReflectiveOperationException {
        var rules = current.rules().naming(object, game, buildings);
        for (var rule : rules) if (rule.included()) return rule.network();
        Position at = buildings.home(object, game.at(object));
        if (at == null) return null;
        for (Network network : current.withArea()) {
            Area area = network.area;
            if (area != null && area.contains(at) && !Rules.excludes(rules, network)) return network;
        }
        return null;
    }

    // The game's thread.

    /** Once a frame: works the networks out again once a second, or when something changed. */
    void frame(Object cells, long now) throws ReflectiveOperationException {
        if (!cadence.due(now)) return;
        unmark(cells);
        var supplyChanged = new ArrayList<Network>();
        var changes = new ArrayList<Change>();
        double hours = game.hours();
        var fresh = new HashSet<Network>();
        var regathered = new HashSet<Network>(); // the consumers it supplies are others now
        supplyHours.clear();
        var totals = new HashMap<Network, Float>();
        List<Network> powered = networks.of(UTILITY);
        // The snapshot is made again only when what it holds changed: a definition, a member's area, a supply.
        boolean again = rebuild;
        rebuild = false;
        var children = new HashMap<String, List<Network>>();
        for (Network network : powered) {
            totals.put(network, network.total);
            Area area = network.area;
            members.resolve(network);
            again |= network.area != area;
            if (network.parents.isEmpty()) producers(network, cells, hours, changes);
            else {
                network.inUse = null;
                children.computeIfAbsent(network.parent(), parent -> new ArrayList<>()).add(network);
            }
            // A network whose consumers were not all loaded is worked out again as one of their chunks loads.
            if (network.loadChanged || !network.loadComplete && arrived(network, cells)) {
                if (network.loadAt == 0) fresh.add(network);
                if (load(network, cells, now)) regathered.add(network);
            }
        }
        var worked = new HashMap<Network, Float>();
        // A child has supply while its parent has, and its parent carries its load; switched off, neither.
        for (Network network : powered) {
            Network root = networks.root(network);
            boolean supplied = root != null && root.inUse != null && networks.switchedOn(network);
            if (supplied != network.supplied) {
                network.supplied = supplied;
                supplyChanged.add(network);
                // When the producer in use started or stopped; for a child, when its parent's did.
                network.suppliedAt = supplyHours.getOrDefault(root, hours);
                changes.add(new Change(network.id, "supply", network.suppliedAt));
            }
            network.total = total(network, children, worked);
        }
        for (Network network : powered)
            if (!fresh.contains(network) && (Math.abs(network.total - totals.get(network)) > 1e-6f || regathered.contains(network)))
                changes.add(new Change(network.id, "load", hours));
        if (again || rebuild || stale || !supplyChanged.isEmpty()) {
            rebuild = false;
            stale = false;
            snapshot = build();
        }
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
        for (Network network : powered)
            for (Position producer : network.squares()) {
                Object generator = generatorAt(cells, producer);
                float consumption = consumption(network, Producer.square(producer));
                if (generator != null && using.getFloat(generator) != consumption) setUsing.invoke(generator, consumption);
            }
        // The objects that gained or lost power update what follows from it (a fridge's hum, a lamp's light).
        for (Network network : supplyChanged)
            for (var consumer : members.consumers(network, Members.POWER, new boolean[1])) checkElectricity.invoke(consumer.object());
        // Last, so that a mod that asks for the state then gets it.
        for (Change change : changes) networks.raise(change.id(), change.what(), change.hour());
    }

    /**
     * Which producer carries the network under {@code "sequential"}: one runs at a time. The one the player switched on
     * last carries it, and the API switches the others off, on standby. When the one in use runs out of fuel or breaks,
     * the API switches on the first other producer, in order, that is on standby and can run, from the hour the first
     * stopped: the game then burns the hours since, as it does for a generator whose square was not loaded. Switched
     * off by the player, the one in use is out of service, and the next on standby takes over now; with none, the
     * network stops. Every generator that is off is on standby but one the API saw switched off by hand, which is out
     * of service: the API never switches it on; switched on by hand, it carries the load and is in service again. A
     * producer whose square is not loaded counts as last seen, and the one in use as stopped once its
     * fuel would have run out. A source is always as its mod last set it: switched on by the mod, it carries the load;
     * no longer available, it stops at the hour the mod gave, and the next takes over from then; switched off by its
     * mod while available, it stops the network. One taken out of the producers while in use stops now, and the next
     * takes over. Switched off (setEnabled), the network runs none: the API switches its generators off, on standby,
     * and its sources are left off; switched on again, the one in use before starts if it can run, or else the next that
     * can take over. One whose square is not loaded carries the network on if it still runs there, and if it is off
     * there with none other to start, the network waits for its square to load. A generator a player switches on
     * meanwhile goes back off at once, and starts first instead; so does a source its mod switches on.
     */
    private void producers(Network network, Object cells, double hours, List<Change> changes) throws ReflectiveOperationException {
        // A multiplayer client follows the server's switches, and keeps no marks: the server owns them.
        boolean authoritative = !client.getBoolean(null);
        var generators = new HashMap<Producer, Object>();
        var loaded = new HashSet<Producer>();
        var newcomers = new ArrayList<Producer>();
        for (Producer producer : network.producers) {
            Seen now;
            if (producer.source() != null) {
                Source source = network.sources.get(producer.source());
                now = new Seen(source.on, source.available ? 1 : 0, source.available ? 1 : 0);
            } else {
                Object generator = generatorAt(cells, producer.at());
                if (generator == null && game.square(cells, producer.at()) == null) {
                    away(network, producer, hours);
                    continue;
                }
                if (generator != null) give(network, producer.at(), generator, hours);
                // A loaded square without the generator: it was taken away.
                now = generator == null ? new Seen(false, 0, 0)
                    : new Seen((boolean)activated.invoke(generator), (float)fuel.invoke(generator), (int)condition.invoke(generator));
                if (generator != null) generators.put(producer, generator);
            }
            loaded.add(producer);
            Seen last = network.seen.put(producer, now);
            if (producer.source() == null) {
                Object generator = generators.get(producer);
                if (generator == null) network.outOfService.remove(producer);
                else service(network, producer, generator, now, last, authoritative);
            }
            // Switched on since last seen; a source only its mod switches, so one on at first sight was switched on too.
            if (now.activated() && (last == null ? producer.source() != null : !last.activated())) newcomers.add(producer);
        }
        // The one in use as the API knew it, or one the game ran before the API knew which (see generatorUpdate).
        Producer before = network.inUse, current = before != null ? before : network.adopted, inUse = current;
        network.adopted = null;
        double at = hours;
        boolean waiting = false;
        if (!network.enabled) {
            // Switched off: no producer runs, and the API switches the generators off, on standby. The one in use
            // starts first when the network is switched on again; one a player switches on meanwhile is in service
            // again, and goes back off at once to start first instead.
            if (!network.stopped) {
                network.stopped = true;
                if (current != null) network.resume = current;
            }
            if (!newcomers.isEmpty()) network.resume = newcomers.get(0);
            else if (network.resume == null)
                for (Producer producer : network.producers)
                    if (loaded.contains(producer) && network.seen.get(producer).activated()) { network.resume = producer; break; }
            inUse = null;
        } else if (network.stopped) {
            // Switched on again: the one in use before starts if it can run, or the first on standby that can. One whose
            // square is not loaded that still runs there (it was not loaded when the network was switched off) carries
            // it on, as the one in use; one that is off there, with none other to start, starts as its square loads.
            Producer resume = network.resume;
            Seen state = resume == null || !network.producers.contains(resume) ? null : network.seen.get(resume);
            boolean away = state != null && resume.at() != null && !loaded.contains(resume);
            // Running there as the API runs it (see away): it has not stopped.
            if (state != null && candidate(network, resume, generators)) inUse = resume;
            else if (away && state.activated() && state.canRun()) inUse = resume;
            else {
                inUse = next(network, resume, generators);
                waiting = inUse == null && away && !state.activated() && state.canRun() && !network.outOfService.contains(resume);
            }
        } else if (current != null && !network.producers.contains(current)) {
            // Taken out of the producers while it carried the load (a generator disconnected, a source its mod
            // dropped): the next one takes over now.
            inUse = next(network, current, generators);
        } else if (current != null && network.seen.containsKey(current)) {
            Seen state = network.seen.get(current);
            Settled settled = current.at() == null ? null : network.settled.get(current.at());
            if (loaded.contains(current)) {
                if (!state.activated()) {
                    // Switched off while it can run: a generator by hand, out of service, and the next on standby takes
                    // over now; a source by its mod, which stops the network.
                    if (state.canRun()) inUse = current.source() != null ? null : next(network, current, generators);
                    else {
                        at = Math.min(hours, stoppedAt(network, current, settled, hours));
                        inUse = next(network, current, generators);
                    }
                }
            } else if (!state.activated()) {
                // Stopped where its square is not loaded (see away): the next takes over from that hour.
                at = stoppedAt(network, current, settled, hours);
                inUse = next(network, current, generators);
            }
        }
        if (network.enabled) {
            if (!newcomers.isEmpty() && !newcomers.contains(inUse)) { inUse = newcomers.get(0); at = hours; }
            else if (inUse == null && before == null)
                for (Producer producer : network.producers) {
                    Seen state = network.seen.get(producer);
                    if (loaded.contains(producer) && state.activated()) { inUse = producer; break; }
                }
            // Switched on again: done once a producer runs, or when none waits for its square to load.
            if (inUse != null || !waiting) network.stopped = false;
        }
        if (!network.stopped) network.resume = null;
        // A client starts and stops nothing: the one in use is one that runs.
        if (!authoritative && inUse != null && generators.containsKey(inUse) && !network.seen.get(inUse).activated()) {
            inUse = null;
            for (Producer producer : network.producers)
                if (loaded.contains(producer) && network.seen.get(producer).activated()) { inUse = producer; break; }
        }
        network.inUse = inUse;
        for (var entry : authoritative ? generators.entrySet() : Set.<Map.Entry<Producer, Object>>of()) {
            Producer producer = entry.getKey();
            Seen state = network.seen.get(producer);
            Object generator = entry.getValue();
            if (producer.equals(inUse) && !state.activated()) {
                // Started by the API, from the hour the last one stopped.
                setActivated.invoke(generator, true);
                lastHour.setInt(generator, (int)Math.floor(at));
                network.seen.put(producer, new Seen(true, state.fuel(), state.condition()));
                mark(generator, RUNNING, true);
            } else if (!producer.equals(inUse) && state.activated()) {
                // Switched off by the API: on standby.
                setActivated.invoke(generator, false);
                network.seen.put(producer, new Seen(false, state.fuel(), state.condition()));
                mark(generator, RUNNING, null);
            }
            // The one to start first as the network is switched on again, also after a world is loaded again.
            boolean resume = network.stopped && producer.equals(network.resume) && !network.outOfService.contains(producer);
            mark(generator, RESUME, resume ? (double)lastHour.getInt(generator) : null);
        }
        // Sources are switched as generators are; the mod reads which is on in the state.
        for (Producer producer : network.producers) {
            if (producer.source() == null) continue;
            Source source = network.sources.get(producer.source());
            boolean on = producer.equals(inUse);
            if (source.on != on) {
                source.on = on;
                Seen state = network.seen.get(producer);
                network.seen.put(producer, new Seen(on, state.fuel(), state.condition()));
            }
        }
        if ((before == null) != (inUse == null)) supplyHours.put(network, at);
        else if (inUse != null && !inUse.equals(before)) changes.add(new Change(network.id, "producer", at));
        if (network.history == null) {
            // First worked out: a producer found running supplied it before; one that ran out while away, until then.
            network.history = new TreeMap<>();
            rebuild = true;
            network.suppliedBefore = current != null || inUse != null;
            if (network.suppliedBefore && inUse == null) remember(network, at, false);
        } else if ((before == null) != (inUse == null)) remember(network, at, inUse != null);
    }

    /** Squares whose generators left the producers of a network; the next frame takes their marks off (see unmark). */
    void left(Collection<Position> squares) { leftSquares.addAll(squares); cadence.changed(); }

    /** The world was left: the squares of its generators are no longer this world's. */
    void forget() { leftSquares.clear(); loose.clear(); }

    /**
     * Takes the marks off the loaded generators that left the producers and are in no network now, and off those the
     * game switched on in no network: the marks say how a network ran them. Only where the game's own state is (not a
     * multiplayer client).
     */
    private void unmark(Object cells) throws ReflectiveOperationException {
        if (leftSquares.isEmpty() && loose.isEmpty()) return;
        var listed = new HashSet<Position>();
        for (Network network : networks.of(UTILITY)) listed.addAll(network.squares());
        boolean authoritative = !client.getBoolean(null);
        for (Position at : leftSquares) {
            Object generator = listed.contains(at) ? null : generatorAt(cells, at);
            if (generator != null && authoritative) for (String key : MARKS) mark(generator, key, null);
        }
        leftSquares.clear();
        for (Object generator; (generator = loose.poll()) != null;) {
            Position at = game.at(generator);
            if (at != null && !listed.contains(at) && authoritative) for (String key : MARKS) mark(generator, key, null);
        }
    }

    private static void remember(Network network, double hour, boolean supplied) {
        network.history.put(hour, supplied);
        while (network.history.size() > MAX_HISTORY) network.suppliedBefore = network.history.pollFirstEntry().getValue();
    }

    /**
     * The first producer of the network, in order, that can run, other than the one that stopped: a source its mod
     * says is available, or a loaded generator on standby.
     */
    private static Producer next(Network network, Producer stopped, Map<Producer, Object> generators) {
        for (Producer producer : network.producers)
            if (!producer.equals(stopped) && candidate(network, producer, generators)) return producer;
        return null;
    }

    /** Whether the API may start the producer: an available source, or a loaded generator on standby that can run. */
    private static boolean candidate(Network network, Producer producer, Map<Producer, Object> generators) {
        Seen state = network.seen.get(producer);
        return state != null && state.canRun()
            && (producer.source() != null || generators.containsKey(producer) && !network.outOfService.contains(producer));
    }

    /**
     * Whether a loaded generator is out of service now (see Network.outOfService), as it was seen last ({@code last},
     * null for the first time since the network was defined or the API took it over) and now; keeps the marks on the
     * generator in step, writing them only as they change. One seen to stop while it can run, also one that ran and
     * stopped between two frames, was switched off by hand: the API's own switches are seen as it makes them. One that
     * stopped and cannot run ran out or broke, and stays on standby. Seen running, it is in service. Seen first, it is out
     * of service by its mark, or when it is off, can run, and was last seen running: switched off where the API did not
     * see it. A client reads the marks the server keeps, and writes none.
     */
    private void service(Network network, Producer producer, Object generator, Seen now, Seen last, boolean authoritative)
            throws ReflectiveOperationException {
        boolean ran = network.ran.remove(producer.at());
        if (!authoritative) {
            if (Boolean.TRUE.equals(mark(generator, OUT_OF_SERVICE)) && !now.activated()) network.outOfService.add(producer);
            else network.outOfService.remove(producer);
            return;
        }
        boolean first = last == null | network.recheck.remove(producer), before = network.outOfService.contains(producer), out;
        if (first) {
            out = !now.activated() && (Boolean.TRUE.equals(mark(generator, OUT_OF_SERVICE))
                || now.canRun() && Boolean.TRUE.equals(mark(generator, RUNNING)));
            // Seen first, the one to start first when its network, switched off, is switched on again (see RESUME).
            if (!out && !now.activated() && !network.enabled && network.resume == null && mark(generator, RESUME) instanceof Double hour
                    && hour.intValue() == lastHour.getInt(generator)) network.resume = producer;
        } else if (now.activated()) out = false;
        else if (last.activated() || ran) out = now.canRun();
        else out = before;
        if (out) network.outOfService.add(producer);
        else network.outOfService.remove(producer);
        if (first || out != before) mark(generator, OUT_OF_SERVICE, out ? true : null);
        if (first || now.activated() != last.activated() || ran && !now.activated()) mark(generator, RUNNING, now.activated() ? true : null);
    }

    /** A mark in a generator's modData, without making its modData; null for none. */
    private Object mark(Object generator, String key) throws ReflectiveOperationException {
        if (hasModData != null && !(boolean)hasModData.invoke(generator, Game.NONE)) return null;
        return lua.get(modData.invoke(generator, Game.NONE), key);
    }

    /** Sets a mark in a generator's modData, or takes it off (null), when it differs. */
    private void mark(Object generator, String key, Object value) throws ReflectiveOperationException {
        if (Objects.equals(mark(generator, key), value)) return;
        lua.set(modData.invoke(generator, Game.NONE), key, value);
    }

    /**
     * When a producer that can no longer run stopped: a source at the hour its mod gave, a generator at the hour it
     * stopped while away (see away), else as it settled.
     */
    private static double stoppedAt(Network network, Producer producer, Settled settled, double hours) {
        if (producer.source() != null) {
            double hour = network.sources.get(producer.source()).stoppedAt;
            return Double.isNaN(hour) ? hours : hour;
        }
        Away away = network.away.get(producer.at());
        if (away != null && !away.on) return away.stoppedAt;
        return settled == null ? hours : settled.end();
    }

    /**
     * A generator that runs on a square that is not loaded. The game would burn the hours away all at once as the
     * square loads, and roll a breakdown once; so the API runs it there hour by hour, from the hour the game last burned
     * it up to (Settled), as the game's update does while it is loaded: its fuel; its condition, worn by 1 or 2 one hour
     * in its item's ConditionLowerChanceOneIn; and at {@link #BREAKDOWN_CONDITION} or below a breakdown, by fire one
     * hour in {@link #FIRE_ONE_IN}, else by explosion one in {@link #EXPLOSION_ONE_IN}. A breakdown leaves its
     * condition 0 and switches it off, without fire or explosion, which cannot start on a square that is not loaded. It
     * stops in the hour its fuel runs out, its condition reaches 0 or it breaks down, and the next producer takes over
     * from then. What the API finds is the producer's last seen state; the generator takes it as its square loads (see
     * give).
     */
    private void away(Network network, Producer producer, double hours) {
        Position at = producer.at();
        Settled settled = network.settled.get(at);
        Away away = network.away.get(at);
        if (away == null) {
            Seen seen = network.seen.get(producer);
            if (seen == null || !seen.activated() || settled == null) return;
            network.away.put(at, away = new Away(settled.lastHour(), settled.fuel(), seen.condition()));
        }
        if (away.given || !away.on || settled == null) return;
        int hour = away.hour;
        run(away, settled, hours);
        if (away.hour != hour) network.seen.put(producer, new Seen(away.on, away.fuel, away.condition));
    }

    /** Runs a generator away hour by hour up to the hour {@code hours} is in (see away). */
    static void run(Away away, Settled settled, double hours) {
        int now = (int)Math.floor(hours);
        while (away.on && away.hour < now) {
            away.hour++;
            away.fuel -= settled.perHour();
            if (dice.applyAsInt(Math.max(1, settled.wearChance())) == 0) away.condition -= dice.applyAsInt(2) + 1;
            if (away.fuel <= 0) { away.fuel = 0; away.on = false; }
            if (away.condition <= 0) { away.condition = 0; away.on = false; }
            if (away.condition <= BREAKDOWN_CONDITION
                    && (dice.applyAsInt(FIRE_ONE_IN) == 0 || dice.applyAsInt(EXPLOSION_ONE_IN) == 0)) {
                away.condition = 0;
                away.on = false;
            }
            if (!away.on) away.stoppedAt = away.hour;
        }
    }

    /**
     * A generator whose square loaded takes what it ran away (see away), before the game's update and before the API
     * reads it: its fuel and condition, its {@code lastHour} the hour the API ran it up to, so that the game burns no hour
     * twice and rolls no breakdown for them; switched off if it stopped. Only where the game's own state is: a
     * multiplayer client follows the server.
     */
    private void give(Network network, Position at, Object generator, double hours) throws ReflectiveOperationException {
        Away away = network.away.get(at);
        if (away == null || away.given) return;
        Settled settled = network.settled.get(at);
        if (settled != null) run(away, settled, hours);
        if (client.getBoolean(null) || !(boolean)activated.invoke(generator)) { network.away.remove(at); return; }
        setFuel.invoke(generator, away.fuel);
        setCondition.invoke(generator, away.condition);
        lastHour.setInt(generator, away.hour);
        if (away.on) { network.away.remove(at); return; }
        away.given = true;
        setActivated.invoke(generator, false);
        // It stopped by itself: on standby, not out of service.
        mark(generator, RUNNING, null);
    }

    /** One hour in how many a generator's condition wears: its item's ConditionLowerChanceOneIn. */
    private int wearChance(Object generator) throws ReflectiveOperationException {
        if (itemType == null) return WEAR_ONE_IN;
        Object type = itemType.invoke(generator);
        Object item = type == null ? null : scriptItem.invoke(scripts.get(null), type);
        int chance = item == null ? 0 : (int)lowerChance.invoke(item);
        return chance > 0 ? chance : WEAR_ONE_IN;
    }

    /**
     * What a producer of the network burns: its own base consumption, and the load of the network and its children when
     * it carries it and the network is switched on.
     */
    private float consumption(Network network, Producer producer) throws IllegalAccessException {
        return basePower.getFloat(null) + (producer.equals(network.inUse) && network.enabled ? network.total : 0f);
    }

    /**
     * The load of the network and of its children that are switched on, theirs included, times its load factor: what it
     * draws while it has supply. Power networks form trees (see Networks.setParents); {@code children} by parent id,
     * {@code worked} what this frame worked out already, so that each network is added up once.
     */
    private static float total(Network network, Map<String, List<Network>> children, Map<Network, Float> worked) {
        Float known = worked.get(network);
        if (known != null) return known;
        float total = network.load;
        for (Network child : children.getOrDefault(network.id, List.of())) if (child.enabled) total += total(child, children, worked);
        total *= network.loadFactor;
        worked.put(network, total);
        return total;
    }

    /** Whether one of the chunks a network's consumers were missing from has loaded since its load was worked out. */
    private boolean arrived(Network network, Object cells) throws ReflectiveOperationException {
        for (long chunk : network.waiting) if (game.chunkLoaded(cells, chunk)) return true;
        return false;
    }

    /**
     * The litres of fuel a generator burns an hour carrying the network's load now: its base consumption and the load of
     * the network at the top of the child's parents, times the sandbox's fuel rate. Whatever carries the load, and with
     * nothing in use; null when a parent is missing.
     */
    Double fuelPerHour(Network network) throws ReflectiveOperationException {
        Network root = networks.root(network);
        if (root == null) return null;
        return (basePower.getFloat(null) + root.total) * (double)optionValue.invoke(fuelRate.get(sandbox.get(null)));
    }

    /**
     * How long the network's supply lasts at its load now: the fuel of its producer in use and of those that can take
     * over, as last seen, over what the one in use would burn an hour. Null without supply or without consumption, and
     * while a source carries it (its mod knows what it holds).
     */
    Double hoursLeft(Network network) throws ReflectiveOperationException {
        Network root = networks.root(network);
        if (root == null || root.inUse == null || root.inUse.source() != null || !networks.switchedOn(network)) return null;
        double perHour = fuelPerHour(network);
        if (perHour <= 0) return null;
        double fuel = 0;
        for (Producer producer : root.producers) {
            if (producer.source() != null) continue;
            Seen state = root.seen.get(producer);
            if (state != null && (producer.equals(root.inUse) || state.canRun() && !root.outOfService.contains(producer))) fuel += state.fuel();
        }
        return fuel / perHour;
    }

    /**
     * The network's load: what its consumers use, the ones on squares that are not loaded as they used it when last
     * seen loaded. Whether the consumers are others than before (one that joined or left can use nothing, so the load
     * alone does not tell).
     */
    private boolean load(Network network, Object cells, long now) throws ReflectiveOperationException {
        boolean[] complete = { true };
        var missing = new HashSet<Long>();
        var next = new LinkedHashMap<Thing, Float>();
        for (var consumer : members.consumers(network, Members.POWER, complete, missing))
            next.put(new Thing(new Position(consumer.x(), consumer.y(), consumer.z()), buildings.sprite(consumer.object())),
                buildings.consumption(consumer.object()));
        for (var last : network.consumption.entrySet()) {
            Position at = last.getKey().at();
            if (!next.containsKey(last.getKey()) && game.square(cells, at) == null) next.put(last.getKey(), last.getValue());
        }
        float load = network.extraLoad;
        for (float value : next.values()) load += value;
        boolean regathered = network.regathered || !next.keySet().equals(network.consumption.keySet());
        network.regathered = false;
        network.consumption = next;
        network.load = load;
        network.loadComplete = complete[0];
        // A square missing from a chunk that is loaded does not come with a chunk load.
        missing.removeIf(chunk -> {
            try { return game.chunkLoaded(cells, chunk); }
            catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
        });
        network.waiting = missing.stream().mapToLong(Long::longValue).toArray();
        network.loadAt = now;
        network.loadChanged = false;
        return regathered;
    }

    private boolean squarePowered(Object square) throws ReflectiveOperationException {
        return square != null && (boolean)squarePowered.invoke(square);
    }

    private Snapshot build() throws ReflectiveOperationException {
        var supplied = new ArrayList<Area>();
        var rooms = new TreeSet<Long>();
        var withArea = new ArrayList<Network>();
        var producers = new HashMap<Position, Network>();
        var histories = new HashMap<Network, History>();
        List<Network> powered = networks.of(UTILITY);
        for (Network network : powered) {
            Network root = networks.root(network);
            if (root != null && root.history != null) histories.put(network, History.of(root, networks.chain(network)));
            boolean on = network.supplied;
            if (network.area != null) { withArea.add(network); if (on) supplied.add(network.area); }
            if (on) for (var building : network.resolved) for (Object room : building.rooms()) rooms.add(buildings.roomId(room));
            for (Position producer : network.squares()) producers.put(producer, network);
        }
        return new Snapshot(supplied.toArray(Area[]::new), rooms.stream().mapToLong(Long::longValue).toArray(), List.copyOf(withArea),
            Map.copyOf(producers), Rules.of(powered, network -> network.supplied), Map.copyOf(histories));
    }

    private Object generatorAt(Object cells, Position at) throws ReflectiveOperationException {
        Object loaded = game.square(cells, at);
        return loaded == null ? null : generatorOf.invoke(loaded);
    }
}
