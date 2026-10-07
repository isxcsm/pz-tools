package pztools.bridge.runtime.api;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import pztools.bridge.ApiHooks;
import pztools.bridge.runtime.api.Members.Area;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Stored;
import pztools.bridge.runtime.api.Network.Thing;
import pztools.bridge.runtime.api.PendingFluids.Delta;

/**
 * Runs the water networks (docs/design/extension-api.md, "Water"): a fixture of a network that has water takes it from
 * the network's fullest producer, through the hooks on the game's water questions; mods draw from and fill the
 * producers, and what is owed to producers whose squares are not loaded goes in as they load. The hooks read an
 * immutable snapshot; the rest runs on the game's thread, once a second or when something changed, and what is owed
 * each frame.
 */
final class WaterGrid implements ApiHooks.Water {
    static final String UTILITY = "water";
    /**
     * In the modData of the containers on a square: the sequence number of the last change owed to it (PendingFluids)
     * that they took. A chunk is saved as it unloads, the global ModData only with the world: a world that stopped
     * between the two owes them changes they took already.
     */
    static final String APPLIED = "PZToolsFluidsApplied";
    private static final long REFRESH_NANOS = TimeUnit.SECONDS.toNanos(1);
    // Raised by the game when an object's fluid changes, so that what keeps its own record of it (rain collectors) follows.
    private static final String AMOUNT_CHANGE = "OnWaterAmountChange";

    /** A network that has water now: its squares, and the producers it draws from (see {@link #producers}). */
    private record Supplier(Network network, Area area, List<Position> producers) { }

    /** An object rule of a network at one square; {@code supplier} is null while the network has no water. */
    private record Rule(String sprite, boolean included, Network network, Supplier supplier) { }

    private record Snapshot(List<Supplier> suppliers, Map<Position, List<Rule>> rules, Set<Position> producers) {
        static final Snapshot EMPTY = new Snapshot(List.of(), Map.of(), Set.of());
    }

    /**
     * One place a draw or fill reaches: a loaded container on a producer's square, or a producer's square that is not
     * loaded (no object), as last seen with what it is owed.
     */
    private record Unit(Position at, Object object, Object container, Stored stored) { }

    private final Members members;
    private final Buildings buildings;
    private final Kahlua lua;
    private final PendingFluids pending;
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change; the next frame works the networks out again.
    private volatile boolean changed = true;
    // Due at the first frame. (Long.MIN_VALUE would overflow the difference: never due.)
    private long refreshedAt = System.nanoTime() - REFRESH_NANOS;
    private final Method fluidContainer, amount, capacity, gameTime, worldHours, triggerEvent;
    private final Method sample, sampleSize, sampleFluid, sampleInstance, instanceAmount, sampleRelease, fluidName, fluidNamed;
    private final Method removeFluid, addFluid, modData, sync, amountChanged;
    private final Field client;

    WaterGrid(ClassLoader loader, Members members, Kahlua lua) throws ReflectiveOperationException {
        this.members = members;
        this.lua = lua;
        buildings = members.buildings();
        pending = new PendingFluids(loader, lua);
        Class<?> object = Class.forName("zombie.iso.IsoObject", false, loader);
        fluidContainer = object.getMethod("getFluidContainer");
        modData = object.getMethod("getModData");
        sync = object.getMethod("sync");
        Class<?> container = Class.forName("zombie.entity.components.fluids.FluidContainer", false, loader);
        Class<?> fluid = Class.forName("zombie.entity.components.fluids.Fluid", false, loader);
        Class<?> fluidSample = Class.forName("zombie.entity.components.fluids.FluidSample", false, loader);
        amount = container.getMethod("getAmount");
        capacity = container.getMethod("getCapacity");
        sample = container.getMethod("createFluidSample");
        removeFluid = container.getMethod("removeFluid", float.class);
        addFluid = container.getMethod("addFluid", fluid, float.class);
        sampleSize = fluidSample.getMethod("size");
        sampleFluid = fluidSample.getMethod("getFluid", int.class);
        sampleInstance = fluidSample.getMethod("getFluidInstance", int.class);
        sampleRelease = fluidSample.getMethod("release");
        instanceAmount = Class.forName("zombie.entity.components.fluids.FluidInstance", false, loader).getMethod("getAmount");
        fluidName = fluid.getMethod("getFluidTypeString");
        fluidNamed = fluid.getMethod("Get", String.class);
        Class<?> time = Class.forName("zombie.GameTime", false, loader);
        gameTime = time.getMethod("getInstance");
        worldHours = time.getMethod("getWorldAgeHours");
        Class<?> events = Class.forName("zombie.Lua.LuaEventManager", false, loader);
        triggerEvent = events.getMethod("triggerEvent", String.class, Object.class, Object.class, Object.class);
        amountChanged = events.getMethod("triggerEvent", String.class, Object.class, Object.class);
        client = Class.forName("zombie.network.GameClient", false, loader).getField("client");
    }

    /**
     * Gives the game's water questions to this grid. Throws a LinkageError in a game whose bootstrap has no water hooks.
     * Here rather than in Networks, which then never names the hooks' Water type, missing from such a bootstrap.
     */
    void hook() { ApiHooks.setWater(this); }

    /** A definition changed: the next frame works the networks out again. */
    void changed() throws ReflectiveOperationException {
        snapshot = snapshot(members.of(UTILITY));
        changed = true;
    }

    // The hooks.

    @Override public boolean plumbed(boolean vanilla, Object fixture) {
        try { return vanilla || supplier(fixture) != null; }
        catch (InvocationTargetException failure) { throw new IllegalStateException(failure.getCause()); }
        catch (ReflectiveOperationException failure) { throw new IllegalStateException(failure); }
    }

    @Override public Object source(Object vanilla, Object fixture) {
        try {
            Supplier supplier = supplier(fixture);
            Object fullest = supplier == null ? null : fullest(supplier.producers(), members.cell());
            return fullest != null ? fullest : vanilla;
        }
        catch (InvocationTargetException failure) { throw new IllegalStateException(failure.getCause()); }
        catch (ReflectiveOperationException failure) { throw new IllegalStateException(failure); }
    }

    /**
     * The network with water that supplies the fixture, for a fixture the game can pipe water to: one that added it on
     * its own, or one whose buildings it stands in and that did not exclude it. A producer's square has no consumers.
     */
    private Supplier supplier(Object fixture) throws ReflectiveOperationException {
        Snapshot current = snapshot;
        if (current.suppliers().isEmpty() || fixture == null) return null;
        Position at = members.at(fixture);
        if (at == null || current.producers().contains(at)) return null;
        Supplier included = null;
        var excluded = new ArrayList<Network>();
        for (Object part : current.rules().isEmpty() ? List.of() : members.parts(fixture)) {
            Thing thing = members.thing(part);
            List<Rule> rules = thing == null ? null : current.rules().get(thing.at());
            if (rules == null) continue;
            for (Rule rule : rules) {
                if (!rule.sprite().equals(thing.sprite())) continue;
                if (!rule.included()) excluded.add(rule.network());
                else if (included == null) included = rule.supplier();
            }
        }
        Supplier found = included;
        for (int index = 0; found == null && index < current.suppliers().size(); index++) {
            Supplier supplier = current.suppliers().get(index);
            if (supplier.area() != null && supplier.area().contains(at) && !excluded.contains(supplier.network())) found = supplier;
        }
        return found != null && buildings.piped(fixture) ? found : null;
    }

    /**
     * The fullest of the producers' loaded fluid containers that holds some, by share of its capacity; null for none. A
     * square owed changes it has not taken yet counts as not loaded (see {@link #applyOwed}).
     */
    private Object fullest(List<Position> producers, Object cells) throws ReflectiveOperationException {
        Object best = null;
        double bestShare = 0;
        for (Position at : producers) {
            Object loaded = pending.owed(at) ? null : members.square(cells, at);
            if (loaded == null) continue;
            for (Object object : buildings.objectsOn(loaded)) {
                Object container = fluidContainer.invoke(object);
                if (container == null) continue;
                float held = (float)amount.invoke(container), most = (float)capacity.invoke(container);
                if (most <= 0 || held <= 0) continue;
                double share = held / most;
                if (best == null || share > bestShare) { best = object; bestShare = share; }
            }
        }
        return best;
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
        if (members.root(network) == null) return result;
        for (Network above : members.chain(network)) result.addAll(above.squares());
        return result;
    }

    /** Reads what is owed again when the world's ModData changed: before a state is reported between two frames. */
    void refreshOwed() throws ReflectiveOperationException { if (authoritative()) pending.refresh(); }

    /** The litres owed to a producer's square, all its changes added up: below 0 for draws. */
    double owed(Position at) { return pending.total(at); }

    /**
     * What a producer's square holds as last seen, with what it is owed added in order: a draw takes from every fluid
     * in proportion, a fill adds as much as there is room for. Null when it was never seen loaded.
     */
    Stored withOwed(Position at, Stored stored) {
        List<Delta> owed = stored == null ? List.of() : pending.at(at);
        if (owed.isEmpty()) return stored;
        var fluids = new HashMap<String, Float>(stored.fluids());
        double held = stored.amount();
        for (Delta delta : owed) {
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
        return new Stored((float)held, stored.capacity(), Map.copyOf(fluids));
    }

    /**
     * Draws up to {@code litres} from the producers the network draws from, the fullest first (see {@link #level}), and
     * adds what it took to {@code mix}, by fluid. A loaded container gives at once; a producer whose square is not
     * loaded is owed the draw, from what it held when last seen and is owed already. Nothing while the network, or a
     * parent above it, is switched off. The litres drawn.
     */
    double draw(Network network, double litres, Map<String, Double> mix) throws ReflectiveOperationException {
        Object cells = members.cell();
        applyOwed(cells);
        List<Unit> units = units(network, cells);
        double[] held = new double[units.size()], most = new double[units.size()];
        for (int index = 0; index < held.length; index++) {
            held[index] = units.get(index).stored().amount();
            most[index] = units.get(index).stored().capacity();
        }
        double[] takes = level(held, most, litres);
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
        changed = true;
        return drawn;
    }

    /**
     * Fills up to {@code litres} of the named fluid into the producers the network draws from, the emptiest first (see
     * {@link #level}), as much as they have room for. A loaded container takes it at once, as far as the game lets it
     * take that fluid; a producer whose square is not loaded is owed the fill. Nothing while the network, or a parent
     * above it, is switched off. The litres filled.
     */
    double fill(Network network, double litres, String fluid) throws ReflectiveOperationException {
        Object cells = members.cell();
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
        changed = true;
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
     * What a draw or fill on the network reaches: the loaded containers on the producers it draws from, and those
     * producers' squares that are not loaded, once seen. None while the network, or a parent above it, is switched off.
     */
    private List<Unit> units(Network network, Object cells) throws ReflectiveOperationException {
        var result = new ArrayList<Unit>();
        if (members.root(network) == null || !members.switchedOn(network)) return result;
        for (Network above : members.chain(network))
            for (Position at : above.squares()) {
                Object loaded = members.square(cells, at);
                if (loaded == null) {
                    Stored stored = withOwed(at, above.stored.get(at));
                    if (stored != null && stored.capacity() > 0) result.add(new Unit(at, null, null, stored));
                    continue;
                }
                for (Object object : buildings.objectsOn(loaded)) {
                    Stored stored = contents(object);
                    if (stored != null) result.add(new Unit(at, object, fluidContainer.invoke(object), stored));
                }
            }
        return result;
    }

    /**
     * Each frame: a square owed changes takes them as soon as it is loaded, before a fixture can draw from it ({@link
     * #fullest} passes over it until then). Several containers on it give the fullest first and take the emptiest first;
     * a square without one drops what it is owed. The containers record the last change they took ({@link #APPLIED}),
     * so that none is taken twice. Only where the game changes what producers hold.
     */
    private void applyOwed(Object cells) throws ReflectiveOperationException {
        if (!authoritative()) return;
        pending.refresh();
        if (pending.isEmpty() || cells == null) return;
        var taken = new ArrayList<Position>();
        for (Position at : pending.squares()) {
            Object loaded = members.square(cells, at);
            if (loaded == null) continue;
            apply(at, loaded);
            taken.add(at);
        }
        if (taken.isEmpty()) return;
        seen(taken, cells);
        changed = true;
    }

    private void apply(Position at, Object loaded) throws ReflectiveOperationException {
        var objects = new ArrayList<Object>();
        var containers = new ArrayList<Object>();
        for (Object object : buildings.objectsOn(loaded)) {
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
        for (Object object : objects)
            if (lua.get(modData.invoke(object), APPLIED) instanceof Double sequence) applied = Math.max(applied, sequence.longValue());
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
        amountChanged.invoke(null, AMOUNT_CHANGE, object, before);
    }

    /** Reads again what loaded producers' squares hold, after they changed. */
    private void seen(Collection<Position> squares, Object cells) throws ReflectiveOperationException {
        if (squares.isEmpty()) return;
        for (Network network : members.of(UTILITY))
            for (Position at : network.squares()) {
                Object loaded = squares.contains(at) ? members.square(cells, at) : null;
                if (loaded != null) network.stored.put(at, held(loaded));
            }
    }

    /** What the containers on a loaded square hold together. */
    private Stored held(Object loaded) throws ReflectiveOperationException {
        float held = 0, most = 0;
        var fluids = new HashMap<String, Float>();
        for (Object object : buildings.objectsOn(loaded)) {
            Stored stored = contents(object);
            if (stored == null) continue;
            held += stored.amount();
            most += stored.capacity();
            stored.fluids().forEach((name, litres) -> fluids.merge(name, litres, Float::sum));
        }
        return new Stored(held, most, Map.copyOf(fluids));
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
        return new Stored((float)amount.invoke(container), most, Map.copyOf(fluids));
    }

    /**
     * Once a frame: takes in what is owed to squares that loaded; and once a second, or when something changed, reads
     * what the producers hold and works out which networks have water. A producer whose square is not loaded counts as
     * last seen, with what it is owed; a network has water while one of the producers it draws from has, and it and
     * each parent above it are switched on.
     */
    void frame(Object cells) throws ReflectiveOperationException {
        applyOwed(cells);
        long now = System.nanoTime();
        boolean due = now - refreshedAt >= REFRESH_NANOS;
        if (!due && !changed) return;
        changed = false;
        if (due) refreshedAt = now;
        List<Network> networks = members.of(UTILITY);
        for (Network network : networks) {
            members.resolve(network);
            for (Position at : network.squares()) {
                Object loaded = members.square(cells, at);
                if (loaded != null) network.stored.put(at, held(loaded));
            }
        }
        double hours = (double)worldHours.invoke(gameTime.invoke(null));
        var supplyChanged = new ArrayList<Network>();
        for (Network network : networks) {
            boolean supplied = members.root(network) != null && members.switchedOn(network) && holds(network);
            if (supplied == network.supplied) continue;
            network.supplied = supplied;
            network.suppliedAt = hours;
            supplyChanged.add(network);
        }
        snapshot = snapshot(networks);
        // Last, so that a mod that asks for the state then gets it.
        for (Network network : supplyChanged) triggerEvent.invoke(null, PowerGrid.EVENT, network.id, "supply", hours);
    }

    /** Whether one of the producers the network draws from holds some, as last seen with what it is owed. */
    private boolean holds(Network network) {
        for (Network above : members.chain(network))
            for (var entry : above.stored.entrySet())
                if (withOwed(entry.getKey(), entry.getValue()).amount() > 0) return true;
        return false;
    }

    private Snapshot snapshot(List<Network> networks) {
        var suppliers = new ArrayList<Supplier>();
        var byNetwork = new HashMap<Network, Supplier>();
        var producers = new HashSet<Position>();
        for (Network network : networks) {
            producers.addAll(network.squares());
            if (!network.supplied || members.root(network) == null) continue;
            var supplier = new Supplier(network, network.area, List.copyOf(producers(network)));
            suppliers.add(supplier);
            byNetwork.put(network, supplier);
        }
        var rules = new HashMap<Position, List<Rule>>();
        for (Network network : networks) {
            Supplier supplier = byNetwork.get(network);
            for (Thing thing : network.excluded)
                rules.computeIfAbsent(thing.at(), at -> new ArrayList<>()).add(new Rule(thing.sprite(), false, network, supplier));
            for (Thing thing : network.included)
                rules.computeIfAbsent(thing.at(), at -> new ArrayList<>()).add(new Rule(thing.sprite(), true, network, supplier));
        }
        rules.replaceAll((at, list) -> List.copyOf(list));
        return new Snapshot(List.copyOf(suppliers), Map.copyOf(rules), Set.copyOf(producers));
    }
}
