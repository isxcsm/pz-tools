package pztools.api;

import java.lang.invoke.*;
import java.lang.reflect.*;
import java.util.*;
import pztools.bridge.ApiHooks;
import pztools.api.Members.Area;
import pztools.api.Network.Position;
import pztools.api.Network.Stored;
import pztools.api.PendingFluids.Delta;

/**
 * Runs the water networks (docs/design/extension-api.md, "Water"): a fixture of a network that has water takes it from
 * a producer the network draws from, as its policy picks ({@link #pick}), through the hooks on the game's water
 * questions; mods draw from and fill the
 * producers, and what is owed to producers whose squares are not loaded goes in as they load. The hooks read an
 * immutable snapshot; the rest runs on the game's thread, once a second or when something changed, and what is owed
 * each frame.
 */
final class WaterGrid implements ApiHooks.Water {
    static final String UTILITY = "water";
    /** Policies: every draw from the fullest container the network draws from; or the nearest network's first. */
    static final String FULLEST = "fullest", NEAREST = "nearest";
    /**
     * Under {@link #NEAREST}, a container at least this full gives first, wherever in the chain it is: water that would
     * be lost (rain into a full collector) is used before water that would not.
     */
    static final double SPILL = 0.95;
    /**
     * In the modData of the containers on a square: the sequence number of the last change owed to it (PendingFluids)
     * that they took. A chunk is saved as it unloads, the global ModData only with the world: a world that stopped
     * between the two owes them changes they took already.
     */
    static final String APPLIED = "PZToolsFluidsApplied";
    // Raised by the game when an object's fluid changes, so that what keeps its own record of it (rain collectors) follows.
    private static final String AMOUNT_CHANGE = "OnWaterAmountChange";

    /**
     * A network that has water now: its squares, the producers it draws from (see {@link #producers}), where each
     * network's of them end in that list ({@code ends}, its own first, then each parent's), whether it draws from the
     * nearest first ({@link #NEAREST}), and whether its fixtures get their water purified.
     */
    private record Supplier(Network network, Area area, List<Position> producers, int[] ends, boolean nearest, boolean purify) { }

    /**
     * {@code unpurified}: whether a supplier does not purify its water, so that the taint questions need a look. Each
     * object rule carries its network's supplier, null while the network has no water.
     */
    private record Snapshot(List<Supplier> suppliers, Rules<Supplier> rules, SquareMap producers, boolean unpurified) {
        static final Snapshot EMPTY = new Snapshot(List.of(), Rules.none(), SquareMap.EMPTY, false);
    }

    /**
     * One place a draw or fill reaches: a loaded container on a producer's square, or a producer's square that is not
     * loaded (no object), as last seen with what it is owed; {@code tier}, how far up the chain its network is (0 the
     * network's own).
     */
    private record Unit(Position at, Object object, Object container, Stored stored, int tier) { }

    private final Game game;
    private final Networks networks;
    private final Members members;
    private final Buildings buildings;
    private final Kahlua lua;
    private final PendingFluids pending;
    private final Cadence cadence = new Cadence();
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change, made on the thread that changed it; see current().
    private volatile boolean stale;
    private volatile Thread changer;
    private final Method fluidContainer, amount, capacity;
    // The same three for pick, the hook's path: invokeExact, no argument arrays, no boxed floats.
    private final MethodHandle containerOf, amountOf, capacityOf;
    private final Method sample, scaledSample, sampleSize, sampleFluid, sampleInstance, instanceAmount, sampleRelease, fluidName, fluidNamed;
    private final Method createContainer, isTainted;
    private final Method removeFluid, addFluid, modData, sync;
    // IsoObject.hasModData, which reads an object's modData without making it; null for a game without it.
    private final Method hasModData;
    private final Field client;

    WaterGrid(ClassLoader loader, Game game, Networks networks, Members members, Buildings buildings, Kahlua lua)
            throws ReflectiveOperationException {
        this.game = game;
        this.networks = networks;
        this.members = members;
        this.buildings = buildings;
        this.lua = lua;
        pending = new PendingFluids(loader, lua);
        Class<?> object = game.objectType;
        fluidContainer = object.getMethod("getFluidContainer");
        modData = object.getMethod("getModData");
        Method has;
        try { has = object.getMethod("hasModData"); }
        catch (NoSuchMethodException none) { has = null; }
        hasModData = has;
        sync = object.getMethod("sync");
        Class<?> container = Game.type(loader, "zombie.entity.components.fluids.FluidContainer");
        Class<?> fluid = Game.type(loader, "zombie.entity.components.fluids.Fluid");
        Class<?> fluidSample = Game.type(loader, "zombie.entity.components.fluids.FluidSample");
        amount = container.getMethod("getAmount");
        capacity = container.getMethod("getCapacity");
        containerOf = Game.exact(fluidContainer, MethodType.methodType(Object.class, Object.class));
        amountOf = Game.exact(amount, MethodType.methodType(float.class, Object.class));
        capacityOf = Game.exact(capacity, MethodType.methodType(float.class, Object.class));
        sample = container.getMethod("createFluidSample");
        scaledSample = container.getMethod("createFluidSample", float.class);
        createContainer = container.getMethod("CreateContainer");
        isTainted = container.getMethod("isTainted");
        removeFluid = container.getMethod("removeFluid", float.class);
        addFluid = container.getMethod("addFluid", fluid, float.class);
        sampleSize = fluidSample.getMethod("size");
        sampleFluid = fluidSample.getMethod("getFluid", int.class);
        sampleInstance = fluidSample.getMethod("getFluidInstance", int.class);
        sampleRelease = fluidSample.getMethod("release");
        instanceAmount = Game.type(loader, "zombie.entity.components.fluids.FluidInstance").getMethod("getAmount");
        fluidName = fluid.getMethod("getFluidTypeString");
        fluidNamed = fluid.getMethod("Get", String.class);
        client = Game.type(loader, "zombie.network.GameClient").getField("client");
    }

    /**
     * Gives the game's water questions to this grid. Throws a LinkageError in a game whose bootstrap has no water hooks.
     * Here rather than in Networks, which then never names the hooks' Water type, missing from such a bootstrap.
     */
    void hook() { ApiHooks.setWater(this); }

    /**
     * A definition changed: the hooks know the definitions at once on the thread that changed them, and the next frame
     * works the networks out again. Many changes in a row make one snapshot, not one each.
     */
    void changed() {
        changer = Thread.currentThread();
        stale = true;
        cadence.changed();
    }

    /** What the hooks read, made again on the thread that changed a definition (as PowerGrid.current). */
    private Snapshot current() {
        if (stale && Thread.currentThread() == changer) {
            stale = false;
            snapshot = build(networks.of(UTILITY));
        }
        return snapshot;
    }

    // The hooks.

    @Override public boolean plumbed(boolean vanilla, Object fixture) {
        try { return vanilla || supplier(fixture) != null; }
        catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    @Override public Object source(Object vanilla, Object fixture) {
        try {
            Supplier supplier = supplier(fixture);
            Object picked = supplier == null ? null : pick(supplier, game.cell());
            return picked != null ? picked : vanilla;
        }
        catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /**
     * For a fixture whose network does not purify its water, a sample of its source as the game makes one, without
     * turning TaintedWater into Water; null, the game's, for any other, and for a source that is not the network's.
     */
    @Override public Object sample(Object fixture, Object source, float amount) {
        if (!current().unpurified() || source == null) return null;
        try {
            Object from = unpurifiedSource(fixture);
            return from != null && fluidContainer.invoke(from) == source ? unpurified(source, amount) : null;
        }
        catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** {@code vanilla}, or the fixture's network does not purify its water and its source holds tainted water. */
    @Override public boolean tainted(boolean vanilla, Object fixture) {
        if (vanilla || !current().unpurified()) return vanilla;
        try {
            Object from = unpurifiedSource(fixture);
            Object container = from == null ? null : fluidContainer.invoke(from);
            return container != null && (boolean)isTainted.invoke(container);
        }
        catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** The producer a fixture takes its water from, when its network does not purify it; null otherwise. */
    private Object unpurifiedSource(Object fixture) throws ReflectiveOperationException {
        Supplier supplier = supplier(fixture);
        return supplier == null || supplier.purify() ? null : pick(supplier, game.cell());
    }

    /** As {@code IsoObject.createSampleAndPurifyWater} makes the sample, each fluid as it is. */
    private Object unpurified(Object source, float litres) throws ReflectiveOperationException {
        Object result = createContainer.invoke(null);
        litres = Math.max(0, Math.min(litres, (float)amount.invoke(source)));
        Object copy = scaledSample.invoke(source, 1f);
        try {
            for (int index = 0, count = (int)sampleSize.invoke(copy); index < count; index++)
                addFluid.invoke(result, sampleFluid.invoke(copy, index), litres * (float)instanceAmount.invoke(sampleInstance.invoke(copy, index)));
        } finally { sampleRelease.invoke(copy); }
        return result;
    }

    /** Whether the game's purification of a fixture's water has its hooks; false in a game whose bootstrap has none. */
    boolean purifyHooked() {
        try { return ApiHooks.waterPurifyHooked(); }
        catch (LinkageError olderBootstrap) { return false; }
    }

    /**
     * The network with water that supplies the fixture, for a fixture the game can pipe water to: one that added it on
     * its own, or one whose buildings it stands in and that did not exclude it. A producer's square has no consumers.
     * The game asks about every object it shows: one that takes no pipes costs a look at its sprite, and one that no
     * rule names allocates nothing.
     */
    private Supplier supplier(Object fixture) throws ReflectiveOperationException {
        Snapshot current = current();
        if (current.suppliers().isEmpty() || fixture == null || !buildings.piped(fixture)) return null;
        Object square = game.squareOf(fixture);
        if (square == null) return null;
        int x = game.x(square), y = game.y(square), z = game.z(square);
        if (current.producers().contains(x, y, z)) return null;
        // Read by index: an iterator would allocate.
        var rules = current.rules().naming(fixture, game, buildings);
        for (int index = 0; index < rules.size(); index++)
            if (rules.get(index).included() && rules.get(index).data() != null) return rules.get(index).data();
        int[] step = buildings.homeStep(fixture, x, y, z);
        if (step != null) { x += step[0]; y += step[1]; }
        for (int index = 0; index < current.suppliers().size(); index++) {
            Supplier supplier = current.suppliers().get(index);
            if (supplier.area() != null && supplier.area().contains(x, y, z) && !Rules.excludes(rules, supplier.network())) return supplier;
        }
        return null;
    }

    /**
     * The loaded fluid container a fixture of the supplier's network takes its water from, of those that hold some; null
     * for none. Under {@link #FULLEST} the fullest by share of its capacity. Under {@link #NEAREST} one at least {@link
     * #SPILL} full (the fullest such), else the fullest of the nearest network in the chain that has one holding some:
     * one pass over the containers either way. A square owed changes it has not taken yet counts as not loaded (see
     * {@link #applyOwed}). Asked whenever the game looks at a fixture's water: it allocates nothing (the square's own
     * list, read by index; handles called exactly).
     */
    private Object pick(Supplier supplier, Object cells) throws ReflectiveOperationException {
        try { return pickExact(supplier, cells); }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    private Object pickExact(Supplier supplier, Object cells) throws Throwable {
        List<Position> producers = supplier.producers();
        int[] ends = supplier.ends();
        boolean nearest = supplier.nearest();
        Object best = null, spill = null;
        double bestShare = 0, spillShare = 0;
        int bestTier = Integer.MAX_VALUE, tier = 0;
        for (int index = 0; index < producers.size(); index++) {
            while (tier < ends.length - 1 && index >= ends[tier]) tier++;
            Position at = producers.get(index);
            Object loaded = pending.owed(at) ? null : game.square(cells, at);
            if (loaded == null) continue;
            List<?> objects = game.objectList(loaded);
            for (int each = 0; each < objects.size(); each++) {
                Object object = objects.get(each);
                Object container = (Object)containerOf.invokeExact(object);
                if (container == null) continue;
                float held = (float)amountOf.invokeExact(container), most = (float)capacityOf.invokeExact(container);
                if (most <= 0 || held <= 0) continue;
                double share = (double)held / most;
                if (nearest && share >= SPILL && (spill == null || share > spillShare)) { spill = object; spillShare = share; }
                // Under NEAREST a farther network's containers count only for spilling, once a nearer one has water.
                if (nearest && tier > bestTier) continue;
                if (best == null || tier < bestTier || share > bestShare) { best = object; bestShare = share; bestTier = tier; }
            }
        }
        return spill != null ? spill : best;
    }

    // The game's thread.

    /** Whether this game changes what producers hold: a single-player game, or a multiplayer game's server. */
    boolean authoritative() throws IllegalAccessException { return !client.getBoolean(null); }

    /** Whether the game has a fluid of that name ({@code Fluid.Get}). */
    boolean fluid(String name) throws ReflectiveOperationException { return fluidNamed.invoke(null, name) != null; }

    /**
     * The producers a network draws from: its own, then each parent's up to the one at the top. None when a parent is
     * missing.
     */
    List<Position> producers(Network network) {
        var result = new ArrayList<Position>();
        if (networks.root(network) == null) return result;
        for (Network above : networks.chain(network)) result.addAll(above.squares());
        return result;
    }

    /** The next sequence number of what is owed, for a newer API; and where this one goes on from an earlier one's. */
    long nextSequence() { return pending.next(); }

    void goOnFrom(long sequence) { pending.numberPast(sequence - 1); }

    /** Reads what is owed again when the world's ModData changed: before a state is reported between two frames. */
    void refreshOwed() throws ReflectiveOperationException { if (authoritative()) pending.refresh(); }

    /**
     * The litres owed to a producer's square, all its changes added up (below 0 for draws), but those it took as last
     * seen loaded (see {@link #withOwed}).
     */
    double owed(Position at, Stored stored) {
        double result = 0;
        for (Delta delta : pending.at(at)) if (stored == null || delta.sequence() > stored.taken()) result += delta.litres();
        return result;
    }

    /**
     * What a producer's square holds as last seen, with what it is owed added in order: a draw takes from every fluid
     * in proportion, a fill adds as much as there is room for. Null when it was never seen loaded. A change the square
     * had taken when it was last seen is not owed: a world loaded again after it stopped between saving the square and
     * saving the ModData reads such changes back (see {@link #APPLIED}).
     */
    Stored withOwed(Position at, Stored stored) {
        List<Delta> owed = stored == null ? List.of() : pending.at(at);
        if (owed.isEmpty()) return stored;
        var fluids = new HashMap<String, Float>(stored.fluids());
        double held = stored.amount();
        for (Delta delta : owed) {
            if (delta.sequence() <= stored.taken()) continue;
            if (delta.litres() < 0) {
                double left = Math.max(0, held + delta.litres());
                float scale = held > 0 ? (float)(left / held) : 0;
                fluids.replaceAll((name, litres) -> litres * scale);
                held = left;
            } else {
                double added = Math.min(delta.litres(), Math.max(0, stored.capacity() - held));
                fluids.merge(delta.fluid(), (float)added, Float::sum);
                held += added;
            }
        }
        fluids.values().removeIf(litres -> litres <= 0);
        return new Stored((float)held, stored.capacity(), Map.copyOf(fluids), stored.taken());
    }

    /**
     * Draws up to {@code litres} from the producers the network draws from, the fullest first (see {@link #level}), and
     * adds what it took to {@code mix}, by fluid. A loaded container gives at once; a producer whose square is not
     * loaded is owed the draw, from what it held when last seen and is owed already. Nothing while the network, or a
     * parent above it, is switched off. The litres drawn.
     */
    double draw(Network network, double litres, Map<String, Double> mix) throws ReflectiveOperationException {
        Object cells = game.cell();
        applyOwed(cells);
        List<Unit> units = units(network, cells);
        double[] held = new double[units.size()], most = new double[units.size()];
        int[] tiers = new int[units.size()];
        for (int index = 0; index < held.length; index++) {
            held[index] = units.get(index).stored().amount();
            most[index] = units.get(index).stored().capacity();
            tiers[index] = units.get(index).tier();
        }
        double[] takes = NEAREST.equals(network.policy) ? nearest(held, most, tiers, litres) : level(held, most, litres);
        double drawn = 0;
        var touched = new HashSet<Position>();
        for (int index = 0; index < takes.length; index++) {
            if (takes[index] <= 0) continue;
            Unit unit = units.get(index);
            Stored before = unit.stored();
            double taken = takes[index];
            if (unit.object() != null) {
                removeFluid.invoke(unit.container(), (float)taken);
                taken = before.amount() - (float)amount.invoke(unit.container());
                amountChanged(unit.object(), before.amount());
                touched.add(unit.at());
            } else {
                pending.add(unit.at(), -taken, null);
            }
            double fluids = 0;
            for (float part : before.fluids().values()) fluids += part;
            for (var fluid : before.fluids().entrySet())
                if (fluids > 0) mix.merge(fluid.getKey(), fluid.getValue() * taken / fluids, Double::sum);
            drawn += taken;
        }
        seen(touched, cells);
        cadence.changed();
        return drawn;
    }

    /**
     * Fills up to {@code litres} of the named fluid into the producers the network draws from, the emptiest first (see
     * {@link #level}), as much as they have room for. A loaded container takes it at once, as far as the game lets it
     * take that fluid; a producer whose square is not loaded is owed the fill. Nothing while the network, or a parent
     * above it, is switched off. The litres filled.
     */
    double fill(Network network, double litres, String fluid) throws ReflectiveOperationException {
        Object cells = game.cell();
        applyOwed(cells);
        Object kind = fluidNamed.invoke(null, fluid);
        List<Unit> units = units(network, cells);
        double[] room = new double[units.size()], most = new double[units.size()];
        for (int index = 0; index < room.length; index++) {
            most[index] = units.get(index).stored().capacity();
            room[index] = Math.max(0, most[index] - units.get(index).stored().amount());
        }
        double[] gives = level(room, most, litres);
        double filled = 0;
        var touched = new HashSet<Position>();
        for (int index = 0; index < gives.length; index++) {
            if (gives[index] <= 0) continue;
            Unit unit = units.get(index);
            if (unit.object() != null) {
                float before = (float)amount.invoke(unit.container());
                addFluid.invoke(unit.container(), kind, (float)gives[index]);
                float after = (float)amount.invoke(unit.container());
                if (after == before) continue;
                amountChanged(unit.object(), before);
                touched.add(unit.at());
                filled += after - before;
            } else {
                pending.add(unit.at(), gives[index], fluid);
                filled += gives[index];
            }
        }
        seen(touched, cells);
        cadence.changed();
        return filled;
    }

    /**
     * How much each of several containers gives of {@code litres}, levelling their shares of their capacities: the
     * fullest gives until it is level with the next, then both until they are level with the third, and so on, as many
     * small draws from the fullest would. A fill levels the room left in them the same way, so the emptiest takes first.
     * Never more than they hold.
     */
    static double[] level(double[] held, double[] capacities, double litres) {
        int count = held.length;
        double[] result = new double[count];
        Integer[] order = new Integer[count];
        for (int index = 0; index < count; index++) order[index] = index;
        Arrays.sort(order, Comparator.comparingDouble(index -> -held[index] / capacities[index]));
        double sumHeld = 0, sumCapacity = 0;
        for (int rank = 0; rank < count && litres > 0; rank++) {
            sumHeld += held[order[rank]];
            sumCapacity += capacities[order[rank]];
            // What the ones so far give to come down to the next one's share; enough, or the last, they stop at a share.
            boolean last = rank + 1 == count;
            if (!last && sumHeld - held[order[rank + 1]] / capacities[order[rank + 1]] * sumCapacity < litres) continue;
            double share = Math.max(0, (sumHeld - litres) / sumCapacity);
            for (int above = 0; above <= rank; above++) {
                int unit = order[above];
                result[unit] = Math.max(0, held[unit] - share * capacities[unit]);
            }
            break;
        }
        return result;
    }

    /**
     * How much each of several containers gives of {@code litres} under {@link #NEAREST}: first what is above {@link
     * #SPILL} of their capacities, levelled (see {@link #level}); then the nearest network's containers ({@code tiers}
     * 0), levelled, then the next one up, and so on. Never more than they hold.
     */
    static double[] nearest(double[] held, double[] capacities, int[] tiers, double litres) {
        int count = held.length;
        double[] result = new double[count], left = held.clone(), above = new double[count];
        for (int index = 0; index < count; index++) above[index] = Math.max(0, held[index] - SPILL * capacities[index]);
        double[] spilled = level(above, capacities, litres);
        for (int index = 0; index < count; index++) {
            result[index] = spilled[index];
            left[index] -= spilled[index];
            litres -= spilled[index];
        }
        int top = 0;
        for (int tier : tiers) top = Math.max(top, tier);
        for (int tier = 0; tier <= top && litres > 1e-9; tier++) {
            int size = 0;
            for (int index = 0; index < count; index++) if (tiers[index] == tier) size++;
            if (size == 0) continue;
            double[] someHeld = new double[size], someCapacities = new double[size];
            int[] which = new int[size];
            for (int index = 0, at = 0; index < count; index++) {
                if (tiers[index] != tier) continue;
                which[at] = index;
                someHeld[at] = left[index];
                someCapacities[at++] = capacities[index];
            }
            double[] takes = level(someHeld, someCapacities, litres);
            for (int at = 0; at < size; at++) {
                result[which[at]] += takes[at];
                litres -= takes[at];
            }
        }
        return result;
    }

    /**
     * What a draw or fill on the network reaches: the loaded containers on the producers it draws from, and those
     * producers' squares that are not loaded, once seen. None while the network, or a parent above it, is switched off.
     */
    private List<Unit> units(Network network, Object cells) throws ReflectiveOperationException {
        var result = new ArrayList<Unit>();
        if (networks.root(network) == null || !networks.switchedOn(network)) return result;
        int tier = 0;
        for (Network above : networks.chain(network)) {
            for (Position at : above.squares()) {
                Object loaded = game.square(cells, at);
                if (loaded == null) {
                    Stored stored = withOwed(at, above.stored.get(at));
                    if (stored != null && stored.capacity() > 0) result.add(new Unit(at, null, null, stored, tier));
                    continue;
                }
                for (Object object : game.objectsOn(loaded)) {
                    Stored stored = contents(object);
                    if (stored != null) result.add(new Unit(at, object, fluidContainer.invoke(object), stored, tier));
                }
            }
            tier++;
        }
        return result;
    }

    /**
     * Each frame: a square owed changes takes them as soon as it is loaded, before a fixture can draw from it ({@link
     * #pick} passes over it until then). Several containers on it give the fullest first and take the emptiest first;
     * a square without one drops what it is owed. The containers record the last change they took ({@link #APPLIED}),
     * so that none is taken twice. Only where the game changes what producers hold.
     */
    private void applyOwed(Object cells) throws ReflectiveOperationException { applyOwed(cells, true); }

    /** {@code read}: the changes are read from the ModData first, if it is another table than they were last read from. */
    private void applyOwed(Object cells, boolean read) throws ReflectiveOperationException {
        if (!read && pending.isEmpty()) return;
        if (!authoritative()) return;
        if (read) pending.refresh();
        if (pending.isEmpty() || cells == null) return;
        var taken = new ArrayList<Position>();
        for (Position at : pending.squares()) {
            Object loaded = game.square(cells, at);
            if (loaded == null) continue;
            apply(at, loaded);
            taken.add(at);
        }
        if (taken.isEmpty()) return;
        seen(taken, cells);
        cadence.changed();
    }

    private void apply(Position at, Object loaded) throws ReflectiveOperationException {
        var objects = new ArrayList<Object>();
        var containers = new ArrayList<Object>();
        for (Object object : game.objectsOn(loaded)) {
            Object container = fluidContainer.invoke(object);
            if (container != null && (float)capacity.invoke(container) > 0) { objects.add(object); containers.add(container); }
        }
        List<Delta> owed = pending.at(at);
        if (objects.isEmpty()) {
            System.err.println("[PzTools API] networks: " + at + " has no fluid container; " + owed.size() + " change(s) owed to it dropped");
            pending.remove(at);
            return;
        }
        long applied = Long.MIN_VALUE;
        for (Object object : objects) applied = Math.max(applied, taken(object));
        float[] before = new float[objects.size()];
        double[] held = new double[objects.size()], most = new double[objects.size()];
        for (int index = 0; index < before.length; index++) before[index] = (float)amount.invoke(containers.get(index));
        long last = applied;
        for (Delta delta : owed) {
            if (delta.sequence() <= applied) continue;
            last = delta.sequence();
            Object kind = delta.litres() > 0 ? fluidNamed.invoke(null, delta.fluid()) : null;
            if (delta.litres() > 0 && kind == null) {
                System.err.println("[PzTools API] networks: the game has no fluid " + delta.fluid() + "; a fill owed to " + at + " dropped");
                continue;
            }
            for (int index = 0; index < held.length; index++) {
                most[index] = (float)capacity.invoke(containers.get(index));
                float now = (float)amount.invoke(containers.get(index));
                held[index] = delta.litres() < 0 ? now : Math.max(0, most[index] - now);
            }
            double[] parts = level(held, most, Math.abs(delta.litres()));
            for (int index = 0; index < parts.length; index++) {
                if (parts[index] <= 0) continue;
                if (delta.litres() < 0) removeFluid.invoke(containers.get(index), (float)parts[index]);
                else addFluid.invoke(containers.get(index), kind, (float)parts[index]);
            }
        }
        if (last != applied) for (Object object : objects) lua.set(modData.invoke(object), APPLIED, (double)last);
        for (int index = 0; index < before.length; index++)
            if ((float)amount.invoke(containers.get(index)) != before[index]) amountChanged(objects.get(index), before[index]);
        pending.remove(at);
    }

    /** As the game does after it changes an object's fluid: the object goes to multiplayer clients, and the event is raised. */
    private void amountChanged(Object object, float before) throws ReflectiveOperationException {
        sync.invoke(object);
        game.raise(AMOUNT_CHANGE, object, before);
    }

    /** Reads again what loaded producers' squares hold, after they changed. */
    private void seen(Collection<Position> squares, Object cells) throws ReflectiveOperationException {
        if (squares.isEmpty()) return;
        for (Network network : networks.of(UTILITY))
            for (Position at : network.squares()) {
                Object loaded = squares.contains(at) ? game.square(cells, at) : null;
                if (loaded != null) network.stored.put(at, held(loaded));
            }
    }

    /** What the containers on a loaded square hold together, and the last change owed to the square that they took. */
    private Stored held(Object loaded) throws ReflectiveOperationException {
        float held = 0, most = 0;
        long taken = Long.MIN_VALUE;
        var fluids = new HashMap<String, Float>();
        for (Object object : game.objectsOn(loaded)) {
            Stored stored = contents(object);
            if (stored == null) continue;
            held += stored.amount();
            most += stored.capacity();
            stored.fluids().forEach((name, litres) -> fluids.merge(name, litres, Float::sum));
            taken = Math.max(taken, taken(object));
        }
        // Later changes are numbered past it, also when the ModData read has older numbers.
        if (taken != Long.MIN_VALUE) pending.numberPast(taken);
        return new Stored(held, most, Map.copyOf(fluids), taken);
    }

    /** The last change owed to its square that the object took ({@link #APPLIED}), without making its modData. */
    private long taken(Object object) throws ReflectiveOperationException {
        if (hasModData != null && !(boolean)hasModData.invoke(object, Game.NONE)) return Long.MIN_VALUE;
        return lua.get(modData.invoke(object, Game.NONE), APPLIED) instanceof Double sequence ? sequence.longValue() : Long.MIN_VALUE;
    }

    /** What the object's own fluid container holds, fluid by fluid; null when it has none. */
    private Stored contents(Object object) throws ReflectiveOperationException {
        Object container = fluidContainer.invoke(object);
        if (container == null) return null;
        float most = (float)capacity.invoke(container);
        if (most <= 0) return null;
        var fluids = new HashMap<String, Float>();
        Object copy = sample.invoke(container);
        try {
            for (int index = 0, count = (int)sampleSize.invoke(copy); index < count; index++)
                fluids.merge((String)fluidName.invoke(sampleFluid.invoke(copy, index)),
                    (float)instanceAmount.invoke(sampleInstance.invoke(copy, index)), Float::sum);
        } finally { sampleRelease.invoke(copy); }
        fluids.values().removeIf(litres -> litres <= 0);
        return new Stored((float)amount.invoke(container), most, Map.copyOf(fluids), Long.MIN_VALUE);
    }

    /**
     * Once a frame: takes in what is owed to squares that loaded; and once a second, or when something changed, reads
     * what the producers hold and works out which networks have water. A producer whose square is not loaded counts as
     * last seen, with what it is owed; a network has water while one of the producers it draws from has, and it and
     * each parent above it are switched on.
     */
    void frame(Object cells, long now) throws ReflectiveOperationException {
        // What is owed is read from the world's ModData when a world started (it is loaded before the cell is stored), and once a
        // second with the grid's work; a frame with nothing owed and nothing to read does nothing here.
        boolean world = moves.moved();
        applyOwed(cells, world);
        if (!cadence.due(now)) return;
        if (!world && authoritative()) { pending.refresh(); applyOwed(cells, false); }
        List<Network> watered = networks.of(UTILITY);
        for (Network network : watered) {
            members.resolve(network);
            for (Position at : network.squares()) {
                Object loaded = game.square(cells, at);
                if (loaded != null) network.stored.put(at, held(loaded));
            }
        }
        double hours = game.hours();
        var supplyChanged = new ArrayList<Network>();
        for (Network network : watered) {
            boolean supplied = networks.root(network) != null && networks.switchedOn(network) && holds(network);
            if (supplied == network.supplied) continue;
            network.supplied = supplied;
            network.suppliedAt = hours;
            supplyChanged.add(network);
        }
        stale = false;
        snapshot = build(watered);
        // Last, so that a mod that asks for the state then gets it.
        for (Network network : supplyChanged) networks.raise(network.id, "supply", hours);
    }

    /** Whether one of the producers the network draws from holds some, as last seen with what it is owed. */
    private boolean holds(Network network) {
        for (Network above : networks.chain(network))
            for (var entry : above.stored.entrySet())
                if (withOwed(entry.getKey(), entry.getValue()).amount() > 0) return true;
        return false;
    }

    private Snapshot build(List<Network> watered) {
        var suppliers = new ArrayList<Supplier>();
        var byNetwork = new HashMap<Network, Supplier>();
        var producers = new HashMap<Position, Long>();
        for (Network network : watered) {
            for (Position at : network.squares()) producers.put(at, 1L);
            if (!network.supplied || networks.root(network) == null) continue;
            var chain = networks.chain(network);
            int[] ends = new int[chain.size()];
            int end = 0;
            for (int index = 0; index < ends.length; index++) ends[index] = end += chain.get(index).squares().size();
            var supplier = new Supplier(network, network.area, List.copyOf(producers(network)), ends,
                NEAREST.equals(network.policy), network.purify);
            suppliers.add(supplier);
            byNetwork.put(network, supplier);
        }
        return new Snapshot(List.copyOf(suppliers), Rules.of(watered, byNetwork::get), new SquareMap(producers),
            suppliers.stream().anyMatch(supplier -> !supplier.purify()));
    }
}
