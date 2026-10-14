package pzext.api;

import java.lang.invoke.*;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import pzext.boot.Hooks;
import pzext.api.Members.Area;
import pzext.api.Network.Position;
import pzext.api.Network.Stored;
import pzext.api.PendingFluids.Delta;

/**
 * Runs the water networks (docs/design.md, "Water"): a fixture of a network that has water takes it from
 * a producer the network draws from, as its policy picks ({@link #pick}), through the hooks on the game's water
 * questions; mods draw from and fill the
 * producers, and what is owed to producers whose squares are not loaded goes in as they load. A rain collector whose
 * square is not loaded is reached in the container the game keeps running ({@link MetaContainers}). The hooks read an
 * immutable snapshot; the rest runs on the game's thread, once a second or when something changed, and what is owed
 * each frame.
 */
final class WaterGrid implements Hooks.Water {
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
    static final String APPLIED = "PZExtFluidsApplied";
    // Raised by the game when an object's fluid changes, so that what keeps its own record of it (rain collectors) follows.
    private static final String AMOUNT_CHANGE = "OnWaterAmountChange";

    /**
     * A network that has water now: its squares, the producers it draws from (see {@link #producers}), where each
     * network's of them end in that list ({@code ends}, its own first, then those above it in order), whether it draws
     * from the nearest first ({@link #NEAREST}), whether its fixtures get their water purified, the game's fluids it
     * takes (a container holding any other is passed over), and the last container {@link #pick} picked for it.
     */
    private record Supplier(Network network, Area area, List<Position> producers, int[] ends, boolean nearest, boolean purify,
            Object[] takes, boolean gridFirst, AtomicReference<Picked> last) { }

    /**
     * What {@link #pick} picked for a supplier at a {@link #tick}: the object (null for none), its container and what
     * that held. Within the tick it is picked again only once that container holds another amount.
     */
    private record Picked(long tick, Object object, Object container, float amount) { }

    /**
     * {@code unpurified}: whether a supplier does not purify its water, so that the taint questions need a look. Each
     * object rule carries its network's supplier, null while the network has no water.
     */
    private record Snapshot(List<Supplier> suppliers, Rules<Supplier> rules, SquareMap producers, boolean unpurified, boolean mains,
            Map<Object, Boolean> mainsReach) {
        static final Snapshot EMPTY = new Snapshot(List.of(), Rules.none(), SquareMap.EMPTY, false, false, Map.of());
    }

    /**
     * One place a draw or fill reaches: a loaded container on a producer's square; a loaded fixture's own water there
     * ({@code reserve}: its object, no container); a container the game keeps running on a square that is not loaded (a
     * rain collector's: no object); or a producer's square that is not loaded (neither), as last seen with what it is
     * owed. {@code tier}, how far up the chain its network is (0 the network's own).
     */
    private record Unit(Position at, Object object, Object container, Stored stored, int tier, boolean reserve) {
        Unit(Position at, Object object, Object container, Stored stored, int tier) { this(at, object, container, stored, tier, false); }
    }

    private final Game game;
    private final Networks networks;
    private final Members members;
    private final Buildings buildings;
    private final Kahlua lua;
    private final PendingFluids pending;
    // Null for a game whose meta entities are out of reach: rain collectors far away count as last seen.
    private final MetaContainers metas;
    private final Cadence cadence = new Cadence();
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change, made on the thread that changed it; see current().
    private volatile boolean stale;
    private volatile Thread changer;
    // Set by a definition change: the next frame makes the snapshot again (see frame).
    private volatile boolean rebuild = true;
    // Counts the frames, and the draws and fills between them: a pick holds for one value (see pick).
    private volatile long tick;
    private final Method fluidContainer, amount, capacity;
    // The same three for pick, the hook's path: invokeExact, no argument arrays, no boxed floats; and the litres of one
    // fluid a container holds.
    private final MethodHandle containerOf, amountOf, capacityOf, fluidAmountOf;
    private final Method sample, scaledSample, sampleSize, sampleFluid, sampleInstance, instanceAmount, sampleRelease, fluidName, fluidNamed;
    private final Method createContainer, isTainted;
    // IsoObject.isWaterInfinite (private): whether the mains give a fixture water; the world's day and the water shut-off.
    private final Method waterInfinite, gameTime, worldDays, waterShut;
    private final Field options;
    // Whether the mains run, read once a second.
    private volatile boolean mains;
    // Set while the game's own answer is asked (the networks silent on that thread).
    private static final ThreadLocal<boolean[]> PURE = ThreadLocal.withInitial(() -> new boolean[1]);
    private final Method removeFluid, addFluid, modData, sync;
    // IsoObject.hasModData, which reads an object's modData without making it; null for a game without it.
    private final Method hasModData;
    private final Field client;
    // A fixture's own water as the game keeps it, without a fluid container (IsoObject's reserve, private): whether it
    // is a fixture of the map that keeps some (isUnmovedPipedWaterSource), what it holds and can hold, setting it; and
    // IsoObject.isTaintedWater, which tells its taint (asked with the networks silent).
    private final MethodHandle unmovedOf, reserveOf, reserveMaxOf;
    private final Method setReserve, taintedWater;

    WaterGrid(ClassLoader loader, Game game, Networks networks, Members members, Buildings buildings, Kahlua lua)
            throws ReflectiveOperationException {
        this.game = game;
        this.networks = networks;
        this.members = members;
        this.buildings = buildings;
        this.lua = lua;
        pending = new PendingFluids(loader, lua);
        metas = MetaContainers.of(loader);
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
        fluidAmountOf = Game.exact(container.getMethod("getSpecificFluidAmount", fluid),
            MethodType.methodType(float.class, Object.class, Object.class));
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
        waterInfinite = Game.accessible(object.getDeclaredMethod("isWaterInfinite"));
        unmovedOf = Game.exact(Game.accessible(object.getDeclaredMethod("isUnmovedPipedWaterSource")),
            MethodType.methodType(boolean.class, Object.class));
        reserveOf = Game.exact(Game.accessible(object.getDeclaredMethod("getReserveWaterAmount")),
            MethodType.methodType(float.class, Object.class));
        reserveMaxOf = Game.exact(Game.accessible(object.getDeclaredMethod("getReserveWaterMax")),
            MethodType.methodType(float.class, Object.class));
        setReserve = Game.accessible(object.getDeclaredMethod("setReserveWaterAmount", float.class));
        taintedWater = object.getMethod("isTaintedWater");
        Class<?> time = Game.type(loader, "zombie.GameTime"), sandbox = Game.type(loader, "zombie.SandboxOptions");
        gameTime = time.getMethod("getInstance");
        worldDays = time.getMethod("getWorldAgeDaysSinceBegin");
        options = sandbox.getField("instance");
        waterShut = sandbox.getMethod("getWaterShutModifier");
    }

    /** Whether the mains run, as the game asks it of a fixture (the world's day before the shut-off's). */
    private boolean mainsRun() throws ReflectiveOperationException {
        return (double)worldDays.invoke(gameTime.invoke(null)) < (int)waterShut.invoke(options.get(null));
    }

    /** Whether the mains run, as last read (once a second). */
    boolean mainsOn() { return mains; }

    // A producer's square holds water in stores: a fluid container (a rain collector's), or with none a fixture's own
    // water as the game keeps it (a sink's, a bath's, a toilet's reserve), so that a fixture on a pipe adds its water
    // to the pipe's. The hooks' paths read them without allocating (handles called exactly).

    /** The object's fluid container when it can hold some; null otherwise, its own water then the reserve's if any. */
    private Object storeContainer(Object object) throws Throwable {
        Object container = (Object)containerOf.invokeExact(object);
        return container != null && (float)capacityOf.invokeExact(container) > 0 ? container : null;
    }

    /** Whether an object without a container keeps its own water the game's way: a fixture of the map that can hold some. */
    private boolean keepsReserve(Object object) throws Throwable {
        return (boolean)unmovedOf.invokeExact(object) && (float)reserveMaxOf.invokeExact(object) > 0;
    }

    /** The litres an object holds of its own: its container's, else its reserve's (0 for one with neither). */
    private float ownWater(Object object) throws Throwable {
        Object container = storeContainer(object);
        if (container != null) return (float)amountOf.invokeExact(container);
        return keepsReserve(object) ? (float)reserveOf.invokeExact(object) : 0;
    }

    /** What a fixture keeps of its own water as a store, or null for an object that keeps none. */
    private Stored reserveStored(Object object) throws ReflectiveOperationException {
        try {
            if (!keepsReserve(object)) return null;
            float held = (float)reserveOf.invokeExact(object), most = (float)reserveMaxOf.invokeExact(object);
            return new Stored(held, most, held > 0 ? Map.of(reserveFluid(object), held) : Map.of(), Long.MIN_VALUE);
        }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The fluid of a fixture's own water: tainted as the game says of it, asked with the networks silent. */
    private String reserveFluid(Object object) throws ReflectiveOperationException {
        boolean[] pure = PURE.get();
        boolean was = pure[0];
        pure[0] = true;
        try { return (boolean)taintedWater.invoke(object) ? "TaintedWater" : "Water"; }
        finally { pure[0] = was; }
    }

    /** The litres in a store: a container's, or with none its object's reserve. */
    private float storeAmount(Object object, Object container) throws ReflectiveOperationException {
        try { return container != null ? (float)amountOf.invokeExact(container) : (float)reserveOf.invokeExact(object); }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    private float storeCapacity(Object object, Object container) throws ReflectiveOperationException {
        try { return container != null ? (float)capacityOf.invokeExact(container) : (float)reserveMaxOf.invokeExact(object); }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** Takes litres from a store, every fluid in proportion (a reserve holds one). */
    private void storeRemove(Object object, Object container, float litres) throws ReflectiveOperationException {
        if (container != null) removeFluid.invoke(container, litres);
        else setReserve.invoke(object, Math.max(0, storeAmount(object, null) - litres));
    }

    /**
     * Adds litres of a fluid to a store as far as it has room. A reserve takes only the fluid its fixture gives (clean
     * water but for a fixture the game has tainted): it has no other to hold.
     */
    private void storeAdd(Object object, Object container, Object kind, float litres) throws ReflectiveOperationException {
        if (container != null) { addFluid.invoke(container, kind, litres); return; }
        if (!reserveFluid(object).equals(fluidName.invoke(kind))) return;
        setReserve.invoke(object, Math.min(storeCapacity(object, null), storeAmount(object, null) + litres));
    }

    /**
     * Gives the game's water questions to this grid. Throws a LinkageError in a game whose bootstrap has no water hooks.
     * Here rather than in Networks, which then never names the hooks' Water type, missing from such a bootstrap.
     */
    void hook() { Hooks.setWater(this); }

    /**
     * A definition changed: the hooks know the definitions at once on the thread that changed them, and the next frame
     * works the networks out again. Many changes in a row make one snapshot, not one each.
     */
    void changed() {
        changer = Thread.currentThread();
        stale = true;
        rebuild = true;
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
        try { return Hooks.waterPurifyHooked(); }
        catch (LinkageError olderBootstrap) { return false; }
    }

    /**
     * The network with water that supplies the fixture, for a fixture the game can pipe water to: one that added it on
     * its own, or one whose buildings it stands in and that did not exclude it. On a producer's square only a fixture
     * whose own water is used up is one.
     * The game asks about every object it shows: one that takes no pipes costs a look at its sprite, and one that no
     * rule names allocates nothing.
     */
    private Supplier supplier(Object fixture) throws ReflectiveOperationException {
        Snapshot current = current();
        if (current.suppliers().isEmpty() || fixture == null || PURE.get()[0] || !buildings.piped(fixture)) return null;
        Supplier found = network(current, fixture);
        if (found != null && found.gridFirst() && current.mains() && mains(current, fixture)) return null;
        return found;
    }

    /**
     * Whether the mains give the fixture water (the game's answer with no network: in a room, piped, outside a NoWater
     * zone, not one a player put down), asked once a fixture each snapshot.
     */
    private boolean mains(Snapshot current, Object fixture) throws ReflectiveOperationException {
        Boolean known = current.mainsReach().get(fixture);
        if (known != null) return known;
        boolean[] pure = PURE.get();
        pure[0] = true;
        boolean reach;
        try { reach = (boolean)waterInfinite.invoke(fixture); }
        finally { pure[0] = false; }
        current.mainsReach().put(fixture, reach);
        return reach;
    }

    /** The network with water whose fixture this is (see supplier), the game's mains aside. */
    private Supplier network(Snapshot current, Object fixture) throws ReflectiveOperationException {
        Object square = game.squareOf(fixture);
        if (square == null) return null;
        int x = game.x(square), y = game.y(square), z = game.z(square);
        // On a producer's square only a fixture that holds no water of its own takes the network's: one with its own
        // (its reserve is the network's too) gives that first, and is never its own source.
        try {
            if (current.producers().contains(x, y, z) && ownWater(fixture) > 0) return null;
        }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
        // Read by index: an iterator would allocate.
        var rules = current.rules().naming(fixture, game, buildings);
        for (int index = 0; index < rules.size(); index++)
            if (rules.get(index).included() && rules.get(index).data() != null) return rules.get(index).data();
        int[] step = buildings.homeStep(fixture, x, y, z);
        if (step != null) { x += step[0]; y += step[1]; z += step[2]; }
        for (int index = 0; index < current.suppliers().size(); index++) {
            Supplier supplier = current.suppliers().get(index);
            if (supplier.area() != null && supplier.area().contains(x, y, z) && !Rules.excludes(rules, supplier.network())) return supplier;
        }
        return null;
    }

    /**
     * The loaded store (a fluid container, or a fixture's own water) a fixture of the supplier's network takes its water from, of those that hold some; null
     * for none. Under {@link #FULLEST} the fullest by share of its capacity. Under {@link #NEAREST} one at least {@link
     * #SPILL} full (the fullest such), else the fullest of the nearest network in the chain that has one holding some:
     * one pass over the containers either way. A square owed changes it has not taken yet counts as not loaded (see
     * {@link #applyOwed}). Asked whenever the game looks at a fixture's water, often many times a frame: within a frame
     * the supplier's last pick holds while its container holds what it held (only the game's own use of that container
     * changes it then; the API's draws and fills count as a new frame), so the containers are gone through once. A pick
     * allocates nothing but its record (the square's own list, read by index; handles called exactly).
     */
    private Object pick(Supplier supplier, Object cells) throws ReflectiveOperationException {
        try {
            long now = tick;
            Picked last = supplier.last().get();
            if (last != null && last.tick() == now && (last.object() == null || storeContainer(last.object()) == last.container()
                    && storeAmount(last.object(), last.container()) == last.amount() && game.squareOf(last.object()) != null))
                return last.object();
            Object picked = pickExact(supplier, cells);
            // (a fixture's own water: no container, its reserve's litres)
            Object container = picked == null ? null : storeContainer(picked);
            supplier.last().set(new Picked(now, picked, container, picked == null ? 0 : storeAmount(picked, container)));
            return picked;
        }
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
                Object container = storeContainer(object);
                float held, most;
                if (container != null) {
                    held = (float)amountOf.invokeExact(container);
                    most = (float)capacityOf.invokeExact(container);
                    if (held <= 0) continue;
                    // One holding a fluid the network does not take gives nothing.
                    float taken = 0;
                    Object[] takes = supplier.takes();
                    for (int fluid = 0; fluid < takes.length; fluid++) taken += (float)fluidAmountOf.invokeExact(container, takes[fluid]);
                    if (held - taken > Network.TRACE) continue;
                } else if (keepsReserve(object)) {
                    // a fixture's own water: one fluid
                    held = (float)reserveOf.invokeExact(object);
                    most = (float)reserveMaxOf.invokeExact(object);
                    if (held <= 0 || !supplier.network().fluids.contains(reserveFluid(object))) continue;
                } else continue;
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
     * The producers a network draws from: its own, then those of each network above it in order (Networks.chain). None
     * when one above is missing.
     */
    List<Position> producers(Network network) {
        var result = new ArrayList<Position>();
        List<Network> chain = networks.chain(network);
        if (chain == null) return result;
        for (Network above : chain) result.addAll(above.squares());
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
        if (metas != null) metas.refresh();
        applyOwed(cells);
        tick++;
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
            if (unit.container() != null || unit.reserve()) {
                storeRemove(unit.object(), unit.container(), (float)taken);
                taken = before.amount() - storeAmount(unit.object(), unit.container());
                if (unit.object() != null) amountChanged(unit.object(), before.amount());
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
        if (metas != null) metas.refresh();
        applyOwed(cells);
        tick++;
        Object kind = fluidNamed.invoke(null, fluid);
        List<Unit> units = units(network, cells);
        double[] room = new double[units.size()], most = new double[units.size()];
        for (int index = 0; index < room.length; index++) {
            Unit unit = units.get(index);
            most[index] = unit.stored().capacity();
            room[index] = Math.max(0, most[index] - unit.stored().amount());
            // a fixture's own water takes only the fluid it gives (see storeAdd)
            if (unit.reserve() && !reserveFluid(unit.object()).equals(fluid)) room[index] = 0;
        }
        double[] gives = level(room, most, litres);
        double filled = 0;
        var touched = new HashSet<Position>();
        for (int index = 0; index < gives.length; index++) {
            if (gives[index] <= 0) continue;
            Unit unit = units.get(index);
            if (unit.container() != null || unit.reserve()) {
                float before = storeAmount(unit.object(), unit.container());
                storeAdd(unit.object(), unit.container(), kind, (float)gives[index]);
                float after = storeAmount(unit.object(), unit.container());
                if (after == before) continue;
                if (unit.object() != null) amountChanged(unit.object(), before);
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
     * What a draw or fill on the network reaches: the loaded containers on the producers it draws from, those the game
     * keeps running on producers' squares that are not loaded, and those producers' squares that are not loaded and
     * have none, once seen; not one that holds a fluid the network does not take. None while the network, or one above
     * it, is switched off.
     */
    private List<Unit> units(Network network, Object cells) throws ReflectiveOperationException {
        var result = new ArrayList<Unit>();
        if (!networks.switchedOn(network)) return result;
        int tier = 0;
        for (Network above : networks.chain(network)) {
            for (Position at : above.squares()) {
                Object loaded = game.square(cells, at);
                List<Object> kept = loaded == null && metas != null ? metas.at(at) : List.of();
                for (Object container : kept) {
                    Stored stored = contents(container);
                    if (stored != null && !network.foreign(stored.fluids())) result.add(new Unit(at, null, container, stored, tier));
                }
                if (loaded == null && !kept.isEmpty()) continue;
                if (loaded == null) {
                    Stored stored = withOwed(at, above.stored.get(at));
                    if (stored != null && stored.capacity() > 0 && !network.foreign(stored.fluids()))
                        result.add(new Unit(at, null, null, stored, tier));
                    continue;
                }
                for (Object object : game.objectsOn(loaded)) {
                    Object container = containerIn(object);
                    Stored stored = container != null ? contents(container) : reserveStored(object);
                    if (stored != null && !network.foreign(stored.fluids()))
                        result.add(new Unit(at, object, container, stored, tier, container == null));
                }
            }
            tier++;
        }
        return result;
    }

    /** The object's store container (see storeContainer), off the hooks' paths. */
    private Object containerIn(Object object) throws ReflectiveOperationException {
        try { return storeContainer(object); }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** Whether an object on a producer's square holds water for it: a container that can hold some, or a fixture's own. */
    private boolean isStore(Object object) throws ReflectiveOperationException {
        try { return storeContainer(object) != null || keepsReserve(object); }
        catch (ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /**
     * Each frame: a square owed changes takes them as soon as it is loaded, before a fixture can draw from it ({@link
     * #pick} passes over it until then). Several containers on it give the fullest first and take the emptiest first;
     * a square without one drops what it is owed. The containers record the last change they took ({@link #APPLIED}),
     * so that none is taken twice. A square that is not loaded but whose containers the game keeps running takes them
     * at once, in those containers. Only where the game changes what producers hold.
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
            if (loaded != null) apply(at, loaded);
            else if (metas != null && !metas.at(at).isEmpty()) apply(at, null, metas.at(at));
            else continue;
            taken.add(at);
        }
        if (taken.isEmpty()) return;
        tick++;
        seen(taken, cells);
        cadence.changed();
    }

    private void apply(Position at, Object loaded) throws ReflectiveOperationException {
        var objects = new ArrayList<Object>();
        var containers = new ArrayList<Object>();
        for (Object object : game.objectsOn(loaded)) {
            if (!isStore(object)) continue;
            objects.add(object);
            containers.add(containerIn(object));
        }
        apply(at, objects, containers);
    }

    /**
     * What is owed to a square, into its stores: those of {@code objects} (each its container in {@code kept}, null for
     * a fixture's own water), which record what they took, or with {@code objects} null the containers the game keeps
     * running while the square is not loaded, which have no object to record it on or to tell of the change. A fixture's
     * own water takes no fill of another fluid than it gives.
     */
    private void apply(Position at, List<Object> objects, List<Object> kept) throws ReflectiveOperationException {
        var owners = new ArrayList<Object>();
        var containers = new ArrayList<Object>();
        for (int index = 0; index < kept.size(); index++) {
            Object object = objects == null ? null : objects.get(index), container = kept.get(index);
            if (storeCapacity(object, container) > 0) { owners.add(object); containers.add(container); }
        }
        List<Delta> owed = pending.at(at);
        if (containers.isEmpty()) {
            System.err.println("[PZExt] networks: " + at + " has no fluid store; " + owed.size() + " change(s) owed to it dropped");
            pending.remove(at);
            return;
        }
        long applied = Long.MIN_VALUE;
        if (objects != null) for (Object object : owners) applied = Math.max(applied, taken(object));
        float[] before = new float[containers.size()];
        double[] held = new double[containers.size()], most = new double[containers.size()];
        for (int index = 0; index < before.length; index++) before[index] = storeAmount(owners.get(index), containers.get(index));
        long last = applied;
        for (Delta delta : owed) {
            if (delta.sequence() <= applied) continue;
            last = delta.sequence();
            Object kind = delta.litres() > 0 ? fluidNamed.invoke(null, delta.fluid()) : null;
            if (delta.litres() > 0 && kind == null) {
                System.err.println("[PZExt] networks: the game has no fluid " + delta.fluid() + "; a fill owed to " + at + " dropped");
                continue;
            }
            for (int index = 0; index < held.length; index++) {
                Object owner = owners.get(index), container = containers.get(index);
                most[index] = storeCapacity(owner, container);
                float now = storeAmount(owner, container);
                held[index] = delta.litres() < 0 ? now : Math.max(0, most[index] - now);
                if (delta.litres() > 0 && container == null && !reserveFluid(owner).equals(delta.fluid())) held[index] = 0;
            }
            double[] parts = level(held, most, Math.abs(delta.litres()));
            for (int index = 0; index < parts.length; index++) {
                if (parts[index] <= 0) continue;
                if (delta.litres() < 0) storeRemove(owners.get(index), containers.get(index), (float)parts[index]);
                else storeAdd(owners.get(index), containers.get(index), kind, (float)parts[index]);
            }
        }
        if (objects != null && last != applied) for (Object object : owners) lua.set(modData.invoke(object), APPLIED, (double)last);
        for (int index = 0; objects != null && index < before.length; index++)
            if (storeAmount(owners.get(index), containers.get(index)) != before[index]) amountChanged(owners.get(index), before[index]);
        pending.remove(at);
    }

    /** As the game does after it changes an object's fluid: the object goes to multiplayer clients, and the event is raised. */
    private void amountChanged(Object object, float before) throws ReflectiveOperationException {
        sync.invoke(object);
        game.raise(AMOUNT_CHANGE, object, before);
    }

    /** Reads again what producers' squares that changed hold, loaded or kept running by the game. */
    private void seen(Collection<Position> squares, Object cells) throws ReflectiveOperationException {
        if (squares.isEmpty()) return;
        for (Network network : networks.of(UTILITY))
            for (Position at : network.squares()) {
                Stored stored = squares.contains(at) ? held(at, cells) : null;
                if (stored != null) network.stored.put(at, stored);
            }
    }

    /**
     * What a producer's square holds now: its containers if it is loaded, else those the game keeps running there; null
     * for a square that is not loaded and has none.
     */
    private Stored held(Position at, Object cells) throws ReflectiveOperationException {
        Object loaded = game.square(cells, at);
        if (loaded != null) return held(loaded);
        List<Object> kept = metas == null ? List.of() : metas.at(at);
        if (kept.isEmpty()) return null;
        float held = 0, most = 0;
        var fluids = new HashMap<String, Float>();
        for (Object container : kept) {
            Stored stored = contents(container);
            if (stored == null) continue;
            held += stored.amount();
            most += stored.capacity();
            stored.fluids().forEach((name, litres) -> fluids.merge(name, litres, Float::sum));
        }
        return new Stored(held, most, Map.copyOf(fluids), Long.MIN_VALUE);
    }

    /** What the stores on a loaded square (containers, fixtures' own water) hold together, and the last change owed to the square that they took. */
    private Stored held(Object loaded) throws ReflectiveOperationException {
        float held = 0, most = 0;
        long taken = Long.MIN_VALUE;
        var fluids = new HashMap<String, Float>();
        for (Object object : game.objectsOn(loaded)) {
            Object container = containerIn(object);
            Stored stored = container != null ? contents(container) : reserveStored(object);
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

    /** What a fluid container holds, fluid by fluid; null for none, or one that holds nothing ever. */
    private Stored contents(Object container) throws ReflectiveOperationException {
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
     * what the producers hold and works out which networks have water. A producer whose square is not loaded is read in
     * the container the game keeps running there (a rain collector's), or else counts as last seen, with what it is owed; a network has water while one of the producers it draws from has, and it and
     * each parent above it are switched on.
     */
    void frame(Object cells, long now) throws ReflectiveOperationException {
        // What is owed is read from the world's ModData when a world started (it is loaded before the cell is stored), and once a
        // second with the grid's work; a frame with nothing owed and nothing to read does nothing here.
        tick++;
        boolean world = moves.moved();
        applyOwed(cells, world);
        if (!cadence.due(now)) return;
        if (metas != null) metas.refresh();
        if (!world && authoritative()) { pending.refresh(); applyOwed(cells, false); }
        List<Network> watered = networks.of(UTILITY);
        // The snapshot is made again only when what it holds changed: a definition, a member's area, a supply, the mains.
        boolean again = rebuild;
        rebuild = false;
        boolean running = mainsRun();
        if (running != mains) {
            mains = running;
            again = true;
        }
        for (Network network : watered) {
            Area area = network.area;
            members.resolve(network);
            again |= network.area != area;
            for (Position at : network.squares()) {
                Stored stored = held(at, cells);
                if (stored != null) network.stored.put(at, stored);
            }
        }
        double hours = game.hours();
        var supplyChanged = new ArrayList<Network>();
        for (Network network : watered) {
            boolean supplied = networks.switchedOn(network) && holds(network);
            if (supplied == network.supplied) continue;
            network.supplied = supplied;
            network.suppliedAt = hours;
            supplyChanged.add(network);
        }
        if (again || stale || !supplyChanged.isEmpty()) {
            stale = false;
            snapshot = build(watered);
        }
        // Last, so that a mod that asks for the state then gets it.
        for (Network network : supplyChanged) networks.raise(network.id, "supply", hours);
    }

    /**
     * Whether one of the producers the network draws from holds some, as last seen with what it is owed, of the fluids
     * it takes alone.
     */
    private boolean holds(Network network) {
        for (Network above : networks.chain(network))
            for (var entry : above.stored.entrySet()) {
                Stored stored = withOwed(entry.getKey(), entry.getValue());
                if (stored.amount() > 0 && !network.foreign(stored.fluids())) return true;
            }
        return false;
    }

    private Snapshot build(List<Network> watered) {
        var suppliers = new ArrayList<Supplier>();
        var byNetwork = new HashMap<Network, Supplier>();
        var producers = new HashMap<Position, Long>();
        for (Network network : watered) {
            for (Position at : network.squares()) producers.put(at, 1L);
            var chain = networks.chain(network);
            if (!network.supplied || chain == null) continue;
            int[] ends = new int[chain.size()];
            int end = 0;
            for (int index = 0; index < ends.length; index++) ends[index] = end += chain.get(index).squares().size();
            var takes = new ArrayList<Object>();
            for (String name : network.fluids) {
                try {
                    Object fluid = fluidNamed.invoke(null, name);
                    if (fluid != null) takes.add(fluid);
                } catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
            }
            var supplier = new Supplier(network, network.area, List.copyOf(producers(network)), ends,
                NEAREST.equals(network.policy), network.purify, takes.toArray(), network.gridFirst, new AtomicReference<>());
            suppliers.add(supplier);
            byNetwork.put(network, supplier);
        }
        return new Snapshot(List.copyOf(suppliers), Rules.of(watered, byNetwork::get), new SquareMap(producers),
            suppliers.stream().anyMatch(supplier -> !supplier.purify()), mains,
            Collections.synchronizedMap(new WeakHashMap<>()));
    }
}
