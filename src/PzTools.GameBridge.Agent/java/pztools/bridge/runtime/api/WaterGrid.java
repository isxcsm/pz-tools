package pztools.bridge.runtime.api;

import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import pztools.bridge.ApiHooks;
import pztools.bridge.runtime.api.Members.Area;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Stored;
import pztools.bridge.runtime.api.Network.Thing;

/**
 * Runs the water networks (docs/design/extension-api.md, "Water"): a fixture of a network that has water takes it from
 * the network's fullest producer, through the hooks on the game's water questions. The hooks read an immutable
 * snapshot; the rest runs on the game's thread, once a second or when something changed.
 */
final class WaterGrid implements ApiHooks.Water {
    static final String UTILITY = "water";
    private static final long REFRESH_NANOS = TimeUnit.SECONDS.toNanos(1);

    /** A network that has water now: its squares, and the producers of the network at the top of its parents. */
    private record Supplier(Network network, Area area, List<Position> producers) { }

    /** An object rule of a network at one square; {@code supplier} is null while the network has no water. */
    private record Rule(String sprite, boolean included, Network network, Supplier supplier) { }

    private record Snapshot(List<Supplier> suppliers, Map<Position, List<Rule>> rules, Set<Position> producers) {
        static final Snapshot EMPTY = new Snapshot(List.of(), Map.of(), Set.of());
    }

    private final Members members;
    private final Buildings buildings;
    private volatile Snapshot snapshot = Snapshot.EMPTY;
    // Set by a definition change; the next frame works the networks out again.
    private volatile boolean changed = true;
    // Due at the first frame. (Long.MIN_VALUE would overflow the difference: never due.)
    private long refreshedAt = System.nanoTime() - REFRESH_NANOS;
    private final Method fluidContainer, amount, capacity, gameTime, worldHours, triggerEvent;

    WaterGrid(ClassLoader loader, Members members) throws ReflectiveOperationException {
        this.members = members;
        buildings = members.buildings();
        fluidContainer = Class.forName("zombie.iso.IsoObject", false, loader).getMethod("getFluidContainer");
        Class<?> container = Class.forName("zombie.entity.components.fluids.FluidContainer", false, loader);
        amount = container.getMethod("getAmount");
        capacity = container.getMethod("getCapacity");
        Class<?> time = Class.forName("zombie.GameTime", false, loader);
        gameTime = time.getMethod("getInstance");
        worldHours = time.getMethod("getWorldAgeHours");
        triggerEvent = Class.forName("zombie.Lua.LuaEventManager", false, loader)
            .getMethod("triggerEvent", String.class, Object.class, Object.class, Object.class);
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

    /** The fullest of the producers' loaded fluid containers that holds some, by share of its capacity; null for none. */
    private Object fullest(List<Position> producers, Object cells) throws ReflectiveOperationException {
        Object best = null;
        double bestShare = 0;
        for (Position at : producers) {
            Object loaded = members.square(cells, at);
            if (loaded == null) continue;
            for (Object object : buildings.objectsOn(loaded)) {
                Stored stored = stored(object);
                if (stored == null || stored.amount() <= 0) continue;
                double share = stored.amount() / stored.capacity();
                if (best == null || share > bestShare) { best = object; bestShare = share; }
            }
        }
        return best;
    }

    /** What the object's own fluid container holds, or null when it has none. */
    private Stored stored(Object object) throws ReflectiveOperationException {
        Object container = fluidContainer.invoke(object);
        if (container == null) return null;
        float most = (float)capacity.invoke(container);
        return most > 0 ? new Stored((float)amount.invoke(container), most) : null;
    }

    // The game's thread.

    /**
     * Once a frame: once a second, or when something changed, reads what the producers hold and works out which
     * networks have water. A producer whose square is not loaded counts as last seen; a child has water while the
     * network at the top of its parents has.
     */
    void frame(Object cells) throws ReflectiveOperationException {
        long now = System.nanoTime();
        boolean due = now - refreshedAt >= REFRESH_NANOS;
        if (!due && !changed) return;
        changed = false;
        if (due) refreshedAt = now;
        List<Network> networks = members.of(UTILITY);
        for (Network network : networks) {
            members.resolve(network);
            if (network.parent != null) continue;
            for (Position at : network.producers) {
                Object loaded = members.square(cells, at);
                if (loaded == null) continue;
                float held = 0, most = 0;
                for (Object object : buildings.objectsOn(loaded)) {
                    Stored stored = stored(object);
                    if (stored != null) { held += stored.amount(); most += stored.capacity(); }
                }
                network.stored.put(at, new Stored(held, most));
            }
        }
        double hours = (double)worldHours.invoke(gameTime.invoke(null));
        var supplyChanged = new ArrayList<Network>();
        for (Network network : networks) {
            Network root = members.root(network);
            boolean supplied = root != null && members.switchedOn(network)
                && root.stored.values().stream().anyMatch(stored -> stored.amount() > 0);
            if (supplied == network.supplied) continue;
            network.supplied = supplied;
            network.suppliedAt = hours;
            supplyChanged.add(network);
        }
        snapshot = snapshot(networks);
        // Last, so that a mod that asks for the state then gets it.
        for (Network network : supplyChanged) triggerEvent.invoke(null, PowerGrid.EVENT, network.id, "supply", hours);
    }

    private Snapshot snapshot(List<Network> networks) {
        var suppliers = new ArrayList<Supplier>();
        var byNetwork = new HashMap<Network, Supplier>();
        var producers = new HashSet<Position>();
        for (Network network : networks) {
            producers.addAll(network.producers);
            Network root = members.root(network);
            if (!network.supplied || root == null) continue;
            var supplier = new Supplier(network, network.area, List.copyOf(root.producers));
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
