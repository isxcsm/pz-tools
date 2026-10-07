package pztools.bridge.runtime.api;

import java.util.*;
import java.util.function.Supplier;
import pztools.bridge.ApiHooks;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Producer;
import pztools.bridge.runtime.api.Network.Seen;
import pztools.bridge.runtime.api.Network.Settled;
import pztools.bridge.runtime.api.Network.Source;
import pztools.bridge.runtime.api.Network.Stored;
import pztools.bridge.runtime.api.Network.Thing;

/**
 * {@code PZToolsAPI.networks}: the networks the mods define (docs/design/extension-api.md, "Networks"). Each belongs to
 * the mod whose handle defined it, and only that mod changes it. The definitions are kept in the API table's metatable,
 * so that a newer payload takes them over with what this one knows of them, and are gone with the world they were made
 * in.
 */
final class Networks {
    /** Raised to Lua mods when a network's supply, producer in use or load changes: its id, what, and the hour. */
    static final String EVENT = "OnPZToolsNetworkChange";
    private static final String AREA = "PZToolsAPI.networks.";
    private static final int MAX_SPRITE = 256;
    // The key in the API's metatable, and the version of the text kept there.
    private static final String MIRROR = "networks", FORMAT = "pztools-networks 1";
    // In the API's metatable: the number of the networks that run now, each payload's one more than the last; and what
    // the next payload calls to take them over (see handover). Payloads from before them read the mirror alone.
    private static final String GENERATION = "networksGeneration", HANDOVER = "networksHandover";
    // The version of the text handover gives.
    private static final String STATE = "pztools-network-state 1";
    // The most a load factor multiplies a load by, and the most extra load a network takes.
    private static final double MAX_LOAD_FACTOR = 100, MAX_EXTRA_LOAD = 1000;
    // The most litres one draw or fill moves.
    private static final double MAX_FLUID = 1_000_000;

    /** The mod a handle belongs to, or null when the value is not one of the API's handles. */
    @FunctionalInterface interface Owners { String of(Object handle) throws ReflectiveOperationException; }

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final Object meta;
    private final Owners owners;
    private final Map<String, Network> networks = new LinkedHashMap<>();
    private final Members members;
    private final PowerGrid grid;
    // Null in a game whose bootstrap has no water hooks: started by an install from before them.
    private WaterGrid water;
    // The game's cell when the last frame ran: a world was left when it goes.
    private Object world;
    private boolean reported;
    // Set when a definition changed since the mirror was written; the next frame, or a newer payload, writes it.
    private boolean dirty;
    // This environment's networks as GENERATION numbers them; 0 until register.
    private long generation;

    Networks(Kahlua lua, Game game, Buildings buildings, ClassLoader loader, Object meta, Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        this.meta = meta;
        this.owners = owners;
        members = new Members(game, buildings);
        grid = new PowerGrid(loader, game, this, members, buildings, lua);
        try { water = new WaterGrid(loader, game, this, members, buildings, lua); }
        catch (LinkageError olderBootstrap) { water = null; }
        // The payload this one replaces writes its definitions to the mirror and hands over the rest it knows.
        String state = null;
        if (lua.get(meta, HANDOVER) instanceof Supplier<?> earlier) {
            try { state = (String)earlier.get(); }
            catch (RuntimeException | LinkageError failure) {
                System.err.println("[PzTools API] networks: the earlier payload did not hand them over; they are worked out anew: " + failure);
            }
        }
        Object kept = lua.get(meta, MIRROR);
        load(kept);
        if (state != null) {
            try { restore(state); }
            catch (RuntimeException unreadable) {
                System.err.println("[PzTools API] networks: what the earlier payload knew of them could not be read; they are worked out anew: " + unreadable);
                networks.clear();
                load(kept);
            }
        }
        dirty = false;
        grid.changed();
        if (water != null) water.changed();
    }

    /**
     * Gives the game's power and water questions to these networks. Throws a LinkageError in a game whose bootstrap
     * has no network hooks; one with power hooks alone gets no water networks.
     */
    void hook() {
        ApiHooks.setPower(grid);
        if (water != null) {
            try { water.hook(); }
            catch (LinkageError olderBootstrap) { water = null; }
        }
        if (water == null) System.err.println("[PzTools API] Water networks are not in this game; restart it to use them");
    }

    /** Gives every power and water question back to the game alone. */
    static void unhook() {
        try { ApiHooks.setPower(null); } catch (LinkageError olderBootstrap) { }
        try { ApiHooks.setWater(null); } catch (LinkageError olderBootstrap) { }
    }

    /**
     * No networks run in the environment any more: a payload could not take them over. The functions mods kept from
     * the earlier payload refuse to be called, as they do after a takeover; its handover stays for a later payload.
     */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    /**
     * Sets this area's functions into its table, replacing those of an earlier payload, whose functions then refuse to
     * be called: a mod that kept one (a local copy of {@code PZToolsAPI.networks.define}) would change networks that no
     * longer run, and that a later takeover would read.
     */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        lua.set(meta, HANDOVER, (Supplier<String>)this::handover);
        // Once per game; a Lua environment made later knows it too.
        game.addEvent(EVENT);
        function(table, "define", (call, arguments) -> {
            String owner = owner(arguments, call), id = id(arguments, call);
            String utility = Arguments.string(arguments, 2, call, "utility"), policy = Arguments.string(arguments, 3, call, "policy");
            // The policies that are not built yet ("parallel") give a clear error now.
            String only = switch (utility) {
                case PowerGrid.UTILITY -> "sequential";
                case WaterGrid.UTILITY -> "fullest";
                default -> throw new IllegalArgumentException(call + ": utility must be \"power\" or \"water\"");
            };
            if (!only.equals(policy)) throw new IllegalArgumentException(call + ": policy for " + utility + " must be \"" + only + "\"");
            if (WaterGrid.UTILITY.equals(utility) && water == null)
                throw new IllegalArgumentException(call + ": water networks are not in this game; restart it to use them");
            Network existing = networks.get(id);
            if (existing != null) {
                own(existing, owner, call);
                // Children of another utility have no supply until they get another parent.
                if (!existing.utility.equals(utility)) detachChildren(id);
            }
            networks.put(id, new Network(id, owner, utility, policy));
            changed();
            return new Object[0];
        });
        function(table, "remove", (call, arguments) -> {
            String owner = owner(arguments, call), id = id(arguments, call);
            Network existing = networks.get(id);
            if (existing == null) return new Object[] { false };
            own(existing, owner, call);
            networks.remove(id);
            // Its children have no supply until they get another parent.
            detachChildren(id);
            changed();
            return new Object[] { true };
        });
        function(table, "setProducers", (call, arguments) -> {
            Network network = mine(arguments, call);
            Object list = arguments.length > 2 ? arguments[2] : null;
            if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": producers must be a list of squares");
            // A water child draws from its own producers and its parents'; a power child's parent carries its load.
            if (network.parent != null && lua.get(list, 1.0) != null && PowerGrid.UTILITY.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + network.id + " is a child network; its parent's producers supply it");
            var producers = new ArrayList<Producer>();
            for (int index = 1;; index++) {
                Object item = lua.get(list, (double)index);
                if (item == null) break;
                Producer producer = producer(item, network, call, "producers[" + index + "]");
                String named = producer.at() != null ? producer.at().toString() : "source " + producer.source();
                if (producers.contains(producer)) throw new IllegalArgumentException(call + ": " + named + " is listed twice");
                if (producer.at() != null)
                    for (Network other : networks.values())
                        if (other != network && other.producers.contains(producer))
                            throw new IllegalArgumentException(call + ": " + named + " is a producer of the network " + other.id);
                producers.add(producer);
            }
            if (producers.equals(network.producers)) return new Object[0];
            network.producers.clear();
            network.producers.addAll(producers);
            network.seen.keySet().retainAll(producers);
            network.outOfService.retainAll(producers);
            if (!producers.contains(network.resume)) network.resume = null;
            List<Position> squares = network.squares();
            network.settled.keySet().retainAll(squares);
            network.stored.keySet().retainAll(squares);
            var names = new HashSet<String>();
            for (Producer producer : producers) if (producer.source() != null) names.add(producer.source());
            network.sources.keySet().retainAll(names);
            for (String name : names) network.sources.computeIfAbsent(name, unused -> new Source());
            changed();
            return new Object[0];
        });
        function(table, "setSource", (call, arguments) -> {
            Network network = mine(arguments, call);
            String name = Arguments.string(arguments, 2, call, "name");
            Source source = network.sources.get(name);
            if (source == null) throw new IllegalArgumentException(call + ": " + network.id + " has no source " + name);
            if (!(arguments.length > 3 && arguments[3] instanceof Boolean available))
                throw new IllegalArgumentException(call + ": available must be true or false");
            Object switchOn = arguments.length > 4 ? arguments[4] : null;
            if (switchOn != null && !(switchOn instanceof Boolean))
                throw new IllegalArgumentException(call + ": switchOn must be true, false or nil");
            Object hour = arguments.length > 5 ? arguments[5] : null;
            if (hour != null && !(hour instanceof Double))
                throw new IllegalArgumentException(call + ": hour must be a number or nil");
            if (!available && Boolean.TRUE.equals(switchOn))
                throw new IllegalArgumentException(call + ": a source that is not available cannot be switched on");
            boolean wasAvailable = source.available, wasOn = source.on;
            double wasStopped = source.stoppedAt;
            source.available = available;
            if (!available) {
                source.on = false;
                // When it ran out: now, unless the mod knows it was earlier.
                if (wasAvailable || hour != null) source.stoppedAt = hour != null ? (Double)hour : Double.NaN;
            } else if (switchOn != null) {
                source.on = (Boolean)switchOn;
            }
            if (wasAvailable != source.available || wasOn != source.on || Double.compare(wasStopped, source.stoppedAt) != 0) changed();
            return new Object[0];
        });
        function(table, "setExtraLoad", (call, arguments) -> {
            Network network = mine(arguments, call);
            if (!PowerGrid.UTILITY.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + network.id + " carries " + network.utility + ", which has no load");
            float load = (float)Arguments.number(arguments, 2, call, "load", 0, MAX_EXTRA_LOAD);
            if (network.extraLoad != load) {
                network.extraLoad = load;
                network.loadChanged = true;
                changed();
            }
            return new Object[0];
        });
        function(table, "setParent", (call, arguments) -> {
            Network network = mine(arguments, call);
            Object parentId = arguments.length > 2 ? arguments[2] : null;
            if (parentId == null) {
                if (network.parent != null) { network.parent = null; changed(); }
                return new Object[0];
            }
            if (!(parentId instanceof String text)) throw new IllegalArgumentException(call + ": parent must be a network id or nil");
            Network parent = networks.get(text);
            if (parent == null) throw new IllegalArgumentException(call + ": there is no network " + text);
            own(parent, network.owner, call);
            if (!parent.utility.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + text + " carries " + parent.utility + ", not " + network.utility);
            if (!network.producers.isEmpty() && PowerGrid.UTILITY.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + network.id + " has producers; a child power network has none");
            for (Network above = parent; above != null; above = above.parent == null ? null : networks.get(above.parent))
                if (above == network) throw new IllegalArgumentException(call + ": " + text + " is a child of " + network.id);
            if (!parent.id.equals(network.parent)) { network.parent = parent.id; changed(); }
            return new Object[0];
        });
        function(table, "setEnabled", (call, arguments) -> {
            Network network = mine(arguments, call);
            if (!(arguments.length > 2 && arguments[2] instanceof Boolean on))
                throw new IllegalArgumentException(call + ": on must be true or false");
            if (network.enabled != on) {
                network.enabled = on;
                grid.switched(network);
                changed();
            }
            return new Object[0];
        });
        function(table, "setLoadFactor", (call, arguments) -> {
            Network network = mine(arguments, call);
            if (!PowerGrid.UTILITY.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + network.id + " carries " + network.utility + ", which has no load");
            float factor = (float)Arguments.number(arguments, 2, call, "factor", 0, MAX_LOAD_FACTOR);
            if (network.loadFactor != factor) {
                network.loadFactor = factor;
                changed();
            }
            return new Object[0];
        });
        function(table, "setPurify", (call, arguments) -> {
            Network network = mine(arguments, call);
            if (!WaterGrid.UTILITY.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + network.id + " carries " + network.utility + ", not water");
            if (!(arguments.length > 2 && arguments[2] instanceof Boolean on))
                throw new IllegalArgumentException(call + ": on must be true or false");
            // The hooks that keep the taint are in the bootstrap: a game started before them gets them as it starts again,
            // and one whose IsoObject they did not fit has neither.
            if (!on && (water == null || !water.purifyHooked()))
                throw new IllegalArgumentException(call + ": water that keeps its taint is not in this game; PZToolsAPI.hooks() says why");
            if (network.purify != on) {
                network.purify = on;
                changed();
            }
            return new Object[0];
        });
        function(table, "addBuilding", (call, arguments) -> {
            Network network = mine(arguments, call);
            Position at = square(arguments, 2, call);
            if (!network.buildings.contains(at)) { network.buildings.add(at); changed(); }
            return new Object[] { buildings.buildingAt(at.x(), at.y(), at.z()) != null };
        });
        function(table, "addRoom", (call, arguments) -> {
            Network network = mine(arguments, call);
            Position at = square(arguments, 2, call);
            if (!network.rooms.contains(at)) { network.rooms.add(at); changed(); }
            return new Object[] { buildings.roomOf(at.x(), at.y(), at.z()) != null };
        });
        function(table, "removeRoom", (call, arguments) -> {
            Network network = mine(arguments, call);
            Position at = square(arguments, 2, call);
            Object room = buildings.roomOf(at.x(), at.y(), at.z());
            var named = new ArrayList<Position>();
            for (Position other : network.rooms)
                if (other.equals(at) || room != null && buildings.roomOf(other.x(), other.y(), other.z()) == room) named.add(other);
            if (network.rooms.removeAll(named)) changed();
            return new Object[] { !named.isEmpty() };
        });
        function(table, "removeBuilding", (call, arguments) -> {
            Network network = mine(arguments, call);
            Position at = square(arguments, 2, call);
            var building = buildings.buildingAt(at.x(), at.y(), at.z());
            var named = new ArrayList<Position>();
            for (Position other : network.buildings) {
                var otherBuilding = building == null ? null : buildings.buildingAt(other.x(), other.y(), other.z());
                if (other.equals(at) || otherBuilding != null && otherBuilding.def() == building.def()) named.add(other);
            }
            if (network.buildings.removeAll(named)) changed();
            return new Object[] { !named.isEmpty() };
        });
        function(table, "exclude", (call, arguments) -> {
            Network network = mine(arguments, call);
            Thing thing = thing(arguments, call);
            if (network.included.remove(thing) | network.excluded.add(thing)) consumersChanged(network, thing);
            return new Object[0];
        });
        function(table, "include", (call, arguments) -> {
            Network network = mine(arguments, call);
            Thing thing = thing(arguments, call);
            if (network.excluded.remove(thing) | network.included.add(thing)) consumersChanged(network, thing);
            return new Object[0];
        });
        function(table, "reset", (call, arguments) -> {
            Network network = mine(arguments, call);
            Thing thing = thing(arguments, call);
            if (network.excluded.remove(thing) | network.included.remove(thing)) consumersChanged(network, thing);
            return new Object[0];
        });
        function(table, "state", (call, arguments) -> {
            Network network = networks.get(Arguments.string(arguments, 0, call, "id"));
            if (network == null) return new Object[] { null };
            Object result = lua.table();
            lua.set(result, "owner", network.owner);
            lua.set(result, "utility", network.utility);
            lua.set(result, "policy", network.policy);
            lua.set(result, "supplied", network.supplied);
            lua.set(result, "enabled", network.enabled);
            if (network.parent != null) lua.set(result, "parent", network.parent);
            if (WaterGrid.UTILITY.equals(network.utility)) water(result, network);
            else power(result, network);
            return new Object[] { result };
        });
        function(table, "consumers", (call, arguments) -> {
            Network network = networks.get(Arguments.string(arguments, 0, call, "id"));
            if (network == null || game.cell() == null) return new Object[] { null, false };
            boolean[] complete = { true };
            var result = new ArrayList<Object>();
            var filter = WaterGrid.UTILITY.equals(network.utility) ? Members.WATER : Members.POWER;
            for (var consumer : members.consumers(network, filter, complete)) result.add(buildings.entry(consumer));
            return new Object[] { lua.list(result), complete[0] };
        });
        function(table, "draw", (call, arguments) -> {
            Network network = fluids(arguments, call);
            double litres = Arguments.number(arguments, 2, call, "amount", 0, MAX_FLUID);
            var mix = new TreeMap<String, Double>();
            double drawn = water.draw(network, litres, mix);
            Object taken = lua.table();
            for (var fluid : mix.entrySet()) lua.set(taken, fluid.getKey(), fluid.getValue());
            return new Object[] { drawn, taken };
        });
        function(table, "fill", (call, arguments) -> {
            Network network = fluids(arguments, call);
            double litres = Arguments.number(arguments, 2, call, "amount", 0, MAX_FLUID);
            String fluid = Arguments.string(arguments, 3, call, "fluid");
            if (!water.fluid(fluid))
                throw new IllegalArgumentException(call + ": fluid must name one of the game's fluids, such as \"Water\" or \"TaintedWater\"");
            return new Object[] { water.fill(network, litres, fluid) };
        });
    }

    /**
     * The caller's own water network named by the arguments, for a call that changes what its producers hold: only where
     * the game changes what objects hold, a single-player game or a multiplayer game's server.
     */
    private Network fluids(Object[] arguments, String call) throws ReflectiveOperationException {
        if (water == null) throw new IllegalArgumentException(call + ": water networks are not in this game; restart it to use them");
        if (!water.authoritative())
            throw new IllegalArgumentException(call + ": a multiplayer client cannot change what producers hold; the server does");
        Network network = mine(arguments, call);
        if (!WaterGrid.UTILITY.equals(network.utility))
            throw new IllegalArgumentException(call + ": " + network.id + " carries " + network.utility + ", not fluids");
        return network;
    }

    /** A power network's state: its load, the fuel it burns and how long that lasts, and its producers as last seen. */
    private void power(Object result, Network network) throws ReflectiveOperationException {
        lua.set(result, "load", (double)network.total);
        lua.set(result, "ownLoad", (double)network.load);
        lua.set(result, "extraLoad", (double)network.extraLoad);
        lua.set(result, "loadFactor", (double)network.loadFactor);
        lua.set(result, "complete", network.loadComplete);
        if (network.inUse != null) lua.set(result, "producer", producer(network.inUse));
        Double fuelPerHour = grid.fuelPerHour(network);
        if (fuelPerHour != null) lua.set(result, "fuelPerHour", fuelPerHour);
        Double hoursLeft = grid.hoursLeft(network);
        if (hoursLeft != null) lua.set(result, "hoursLeft", hoursLeft);
        var producers = new ArrayList<Object>();
        for (Producer producer : network.producers) {
            Object entry = producer(producer);
            if (producer.source() != null) {
                Source source = network.sources.get(producer.source());
                lua.set(entry, "running", source.on);
                lua.set(entry, "available", source.available);
                producers.add(entry);
                continue;
            }
            var seen = network.seen.get(producer);
            if (seen != null) {
                lua.set(entry, "running", seen.activated());
                lua.set(entry, "fuel", (double)seen.fuel());
                lua.set(entry, "condition", (double)seen.condition());
                // Switched off by hand: the API never switches it on. Absent, one that is off is on standby.
                if (!seen.activated() && network.outOfService.contains(producer)) lua.set(entry, "outOfService", true);
            }
            producers.add(entry);
        }
        lua.set(result, "producers", lua.list(producers));
    }

    /**
     * A water network's state: what the producers it draws from hold, as last seen and with what draws and fills owe
     * them: its own and, for a child, its parents'. It lists its own.
     */
    private void water(Object result, Network network) throws ReflectiveOperationException {
        double held = 0, most = 0;
        var producers = new ArrayList<Object>();
        if (water != null) water.refreshOwed();
        for (Network above : root(network) == null ? List.<Network>of() : chain(network))
            for (Position at : above.squares()) {
                Object entry = square(at);
                // What draws and fills owe a producer whose square is not loaded counts already.
                var stored = water == null ? above.stored.get(at) : water.withOwed(at, above.stored.get(at));
                if (water != null) lua.set(entry, "pending", water.owed(at, above.stored.get(at)));
                if (stored != null) {
                    lua.set(entry, "amount", (double)stored.amount());
                    lua.set(entry, "capacity", (double)stored.capacity());
                    held += stored.amount();
                    most += stored.capacity();
                }
                if (above == network) producers.add(entry);
            }
        lua.set(result, "amount", held);
        lua.set(result, "capacity", most);
        lua.set(result, "purify", network.purify);
        lua.set(result, "producers", lua.list(producers));
    }

    /** {@code handle:clear()}: removes everything the mod defined. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        if (networks.values().removeIf(network -> network.owner.equals(owner))) changed();
    }

    private void detachChildren(String id) {
        for (Network child : networks.values()) if (id.equals(child.parent)) child.parent = null;
    }

    /** Each frame, on the game's thread. */
    void frame() {
        try {
            Object cell = game.cell();
            // The world the networks were defined in was left; the mods define them again in the next one.
            if (world != null && cell != world && !networks.isEmpty()) { networks.clear(); changed(); }
            world = cell;
            if (cell != null) {
                grid.frame(cell);
                if (water != null) water.frame(cell);
            }
            flush();
        } catch (Throwable failure) {
            // Once: a fault that recurs each frame must not flood the game's log. The hooks keep answering.
            if (!reported) System.err.println("[PzTools API] networks: " + failure);
            reported = true;
        }
    }

    // The networks as the grids see them: trees of one mod's networks of one utility (see setParent).

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

    /** Raises {@link #EVENT}, after a change the grids worked out: the network's id, what changed, and the hour it did. */
    void raise(String id, String what, double hour) throws ReflectiveOperationException { game.raise(EVENT, id, what, hour); }

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            return body.call(call, arguments);
        }));
    }

    /** Refuses a call into networks that a newer payload took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZToolsAPI");
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
        return owner;
    }

    private static String id(Object[] arguments, String call) { return Arguments.name(arguments, 1, call, "id"); }

    private static void own(Network network, String owner, String call) {
        if (!network.owner.equals(owner)) throw new IllegalArgumentException(call + ": " + network.id + " belongs to another mod");
    }

    /** The caller's own network named by the arguments. */
    private Network mine(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owner(arguments, call), id = id(arguments, call);
        Network network = networks.get(id);
        if (network == null) throw new IllegalArgumentException(call + ": there is no network " + id);
        own(network, owner, call);
        return network;
    }

    private static Position square(Object[] arguments, int index, String call) {
        return new Position(Arguments.integer(arguments, index, call, "x"), Arguments.integer(arguments, index + 1, call, "y"),
            Arguments.integer(arguments, index + 2, call, "z"));
    }

    private Position position(Object table, String call, String name) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": " + name + " must be a table with x, y and z");
        Object[] fields = { lua.get(table, "x"), lua.get(table, "y"), lua.get(table, "z") };
        return square(fields, 0, call + ": " + name);
    }

    private static Thing thing(Object[] arguments, String call) {
        Position at = square(arguments, 2, call);
        String sprite = Arguments.string(arguments, 5, call, "sprite");
        if (sprite.isEmpty() || sprite.length() > MAX_SPRITE || sprite.chars().anyMatch(Character::isISOControl))
            throw new IllegalArgumentException(call + ": sprite must be a sprite name");
        return new Thing(at, sprite);
    }

    private Object square(Position at) throws ReflectiveOperationException {
        Object result = lua.table();
        lua.set(result, "x", (double)at.x()); lua.set(result, "y", (double)at.y()); lua.set(result, "z", (double)at.z());
        return result;
    }

    /** A producer as the state gives it: its square, or a table with its source's name. */
    private Object producer(Producer producer) throws ReflectiveOperationException {
        if (producer.at() != null) return square(producer.at());
        Object result = lua.table();
        lua.set(result, "source", producer.source());
        return result;
    }

    /** A producer as a mod lists it: a table with {@code source}, a name, or with {@code x}, {@code y} and {@code z}. */
    private Producer producer(Object item, Network network, String call, String name) throws ReflectiveOperationException {
        Object source = lua.isTable(item) ? lua.get(item, "source") : null;
        if (source == null) return Producer.square(position(item, call, name));
        if (!Arguments.isName(source)) throw new IllegalArgumentException(call + ": " + name + ".source must be " + Arguments.NAME_RULE);
        if (!PowerGrid.UTILITY.equals(network.utility))
            throw new IllegalArgumentException(call + ": " + network.id + " carries " + network.utility + "; sources are for power");
        return Producer.source((String)source);
    }

    /** The network's consumers changed: its load is worked out again, without what was last seen of the object. */
    private void consumersChanged(Network network, Thing thing) {
        if (network.consumption.containsKey(thing)) {
            var consumption = new LinkedHashMap<>(network.consumption);
            consumption.remove(thing);
            network.consumption = consumption;
        }
        network.loadChanged = true;
        changed();
    }

    /**
     * A definition changed: the hooks know it at once (see PowerGrid.changed), the next frame works the networks out
     * again, and writes the mirror. A mod that defines many objects in a row so costs one of each, not one per call.
     */
    private void changed() {
        dirty = true;
        grid.changed();
        if (water != null) water.changed();
    }

    /** Keeps the definitions where a newer payload finds them, when they changed since they were last kept. */
    private void flush() throws ReflectiveOperationException { if (dirty) write(); }

    /**
     * Keeps the definitions where a newer payload finds them, as they are now: with the sources as the frames last
     * switched them, which is no definition change.
     */
    private void write() throws ReflectiveOperationException {
        var text = new StringBuilder(FORMAT).append('\n');
        for (Network network : networks.values()) {
            text.append("N\t").append(network.id).append('\t').append(network.owner).append('\t')
                .append(network.utility).append('\t').append(network.policy).append('\t')
                .append(network.parent == null ? "" : network.parent).append('\t')
                .append(network.enabled ? "" : "off").append('\t')
                .append(network.loadFactor == 1f ? "" : Float.toString(network.loadFactor)).append('\t')
                .append(network.extraLoad == 0f ? "" : Float.toString(network.extraLoad))
                // Added later: a line without it is from an earlier payload, and purifies.
                .append(network.purify ? "" : "\tunpurified").append('\n');
            for (Producer producer : network.producers) {
                if (producer.at() != null) { text.append("P\t").append(producer.at()).append('\n'); continue; }
                Source source = network.sources.get(producer.source());
                text.append("S\t").append(producer.source()).append('\t').append(source.available ? "available" : "")
                    .append('\t').append(source.on ? "on" : "").append('\t')
                    .append(Double.isNaN(source.stoppedAt) ? "" : Double.toString(source.stoppedAt)).append('\n');
            }
            for (Position at : network.buildings) text.append("B\t").append(at).append('\n');
            for (Position at : network.rooms) text.append("R\t").append(at).append('\n');
            for (Thing thing : network.excluded) text.append("X\t").append(thing.at()).append('\t').append(thing.sprite()).append('\n');
            for (Thing thing : network.included) text.append("I\t").append(thing.at()).append('\t').append(thing.sprite()).append('\n');
        }
        lua.set(meta, MIRROR, text.toString());
        dirty = false;
    }

    /** The definitions an earlier payload kept, if any. */
    private void load(Object kept) {
        if (!(kept instanceof String text)) return;
        String[] lines = text.split("\n");
        if (!FORMAT.equals(lines[0])) {
            System.err.println("[PzTools API] networks: the definitions kept are in another format; the mods define them again");
            return;
        }
        Network network = null;
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", -1);
            switch (fields[0]) {
                case "N" -> {
                    networks.put(fields[1], network = new Network(fields[1], fields[2], fields[3], fields[4]));
                    if (fields.length > 5 && !fields[5].isEmpty()) network.parent = fields[5];
                    // Switched off when taken over: off before, as far as the API knows.
                    if (fields.length > 6 && "off".equals(fields[6])) network.enabled = network.enabledBefore = false;
                    if (fields.length > 7 && !fields[7].isEmpty()) network.loadFactor = Float.parseFloat(fields[7]);
                    if (fields.length > 8 && !fields[8].isEmpty()) network.extraLoad = Float.parseFloat(fields[8]);
                    if (fields.length > 9 && "unpurified".equals(fields[9])) network.purify = false;
                }
                case "P" -> network.producers.add(Producer.square(Position.parse(fields[1])));
                case "S" -> {
                    network.producers.add(Producer.source(fields[1]));
                    Source source = new Source();
                    source.available = "available".equals(fields[2]);
                    source.on = "on".equals(fields[3]);
                    if (!fields[4].isEmpty()) source.stoppedAt = Double.parseDouble(fields[4]);
                    network.sources.put(fields[1], source);
                }
                case "B" -> network.buildings.add(Position.parse(fields[1]));
                case "R" -> network.rooms.add(Position.parse(fields[1]));
                case "X" -> network.excluded.add(new Thing(Position.parse(fields[1]), fields[2]));
                case "I" -> network.included.add(new Thing(Position.parse(fields[1]), fields[2]));
                default -> throw new IllegalStateException("Unknown line in the kept networks: " + lines[index]);
            }
        }
    }

    /**
     * Called by a newer payload as it takes over (see {@link #HANDOVER}), on the game's thread: writes the definitions
     * to the mirror, and gives what this payload knows of the networks beyond them, which the mirror does not keep: the
     * producer in use and each producer as last seen, out of service or not, the supply, the load of consumers on
     * squares that are not loaded, and the supply's history for food. A producer running on a square that is not loaded
     * so goes on carrying its network, and one out of service there stays out of service.
     */
    private String handover() {
        try { write(); }
        catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
        var text = new StringBuilder(STATE).append('\n');
        // The numbering of what is owed to water producers goes on from here, never back.
        if (water != null) text.append("Q\t").append(water.nextSequence()).append('\n');
        for (Network network : networks.values()) {
            text.append("N\t").append(network.id).append('\t').append(network.supplied ? "1" : "").append('\t').append(network.suppliedAt)
                .append('\t').append(network.load).append('\t').append(network.total).append('\t').append(network.loadComplete ? "1" : "")
                .append('\t').append(key(network.inUse))
                // Added later: whether the API stopped its producers as it was switched off, and the one to start first.
                .append('\t').append(network.stopped ? "1" : "").append('\t').append(key(network.resume)).append('\n');
            for (var seen : network.seen.entrySet()) {
                // Added later, at the end so that an earlier payload reads the line still: out of service.
                text.append("E\t").append(key(seen.getKey())).append('\t').append(seen.getValue().activated() ? "1" : "").append('\t')
                    .append(seen.getValue().fuel()).append('\t').append(seen.getValue().condition())
                    .append(network.outOfService.contains(seen.getKey()) ? "\tout" : "").append('\n');
            }
            for (var settled : network.settled.entrySet())
                text.append("T\t").append(settled.getKey()).append('\t').append(settled.getValue().lastHour()).append('\t')
                    .append(settled.getValue().fuel()).append('\t').append(settled.getValue().perHour()).append('\n');
            for (var stored : network.stored.entrySet()) {
                text.append("W\t").append(stored.getKey()).append('\t').append(stored.getValue().amount()).append('\t')
                    .append(stored.getValue().capacity()).append('\t').append(stored.getValue().taken());
                for (var fluid : stored.getValue().fluids().entrySet()) text.append('\t').append(fluid.getKey()).append('\t').append(fluid.getValue());
                text.append('\n');
            }
            for (var consumer : network.consumption.entrySet())
                if (consumer.getKey().sprite().chars().noneMatch(Character::isISOControl))
                    text.append("C\t").append(consumer.getKey().at()).append('\t').append(consumer.getValue()).append('\t')
                        .append(consumer.getKey().sprite()).append('\n');
            if (network.history != null) changes(text.append("H\t"), network.history, network.suppliedBefore);
            changes(text.append("O\t"), network.switches, network.enabledBefore);
        }
        return text.toString();
    }

    private static void changes(StringBuilder text, NavigableMap<Double, Boolean> changes, boolean before) {
        text.append(before ? "1" : "");
        for (var change : changes.entrySet()) text.append('\t').append(change.getKey()).append('\t').append(change.getValue() ? "1" : "");
        text.append('\n');
    }

    /** A producer in the text of {@link #handover}: {@code P:} and its square, {@code S:} and its source's name, or none. */
    private static String key(Producer producer) {
        return producer == null ? "" : producer.at() != null ? "P:" + producer.at() : "S:" + producer.source();
    }

    private static Producer producer(String key) {
        if (key.isEmpty()) return null;
        if (key.startsWith("P:")) return Producer.square(Position.parse(key.substring(2)));
        if (key.startsWith("S:")) return Producer.source(key.substring(2));
        throw new IllegalStateException("Not a producer: " + key);
    }

    /**
     * What the payload this one replaced knew of the networks beyond their definitions (see {@link #handover}), for
     * the networks and producers it still defines.
     */
    private void restore(String text) {
        String[] lines = text.split("\n");
        if (!STATE.equals(lines[0])) {
            System.err.println("[PzTools API] networks: what the earlier payload knew of them is in another format; they are worked out anew");
            return;
        }
        Network network = null;
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", -1);
            if ("Q".equals(fields[0])) {
                if (water != null) water.goOnFrom(Long.parseLong(fields[1]));
                continue;
            }
            if ("N".equals(fields[0])) {
                network = networks.get(fields[1]);
                if (network == null) continue;
                network.supplied = "1".equals(fields[2]);
                network.suppliedAt = Double.parseDouble(fields[3]);
                network.load = Float.parseFloat(fields[4]);
                network.total = Float.parseFloat(fields[5]);
                network.loadComplete = "1".equals(fields[6]);
                Producer inUse = producer(fields[7]);
                network.inUse = network.producers.contains(inUse) ? inUse : null;
                // From a payload before them, none: a network it left switched off with its producer running is stopped
                // at the next frame, which starts that producer first when the network is switched on again.
                if (fields.length > 9) {
                    network.stopped = "1".equals(fields[8]);
                    Producer resume = producer(fields[9]);
                    network.resume = network.producers.contains(resume) ? resume : null;
                }
                network.consumption = new LinkedHashMap<>();
                continue;
            }
            if (network == null) continue;
            switch (fields[0]) {
                case "E" -> {
                    Producer producer = producer(fields[1]);
                    if (!network.producers.contains(producer)) continue;
                    network.seen.put(producer, new Seen("1".equals(fields[2]), Float.parseFloat(fields[3]), Integer.parseInt(fields[4])));
                    // From a payload before the marks, none: its generators that are off are on standby, as it ran them.
                    if (fields.length > 5 && "out".equals(fields[5])) network.outOfService.add(producer);
                }
                case "T" -> {
                    Position at = Position.parse(fields[1]);
                    if (network.producers.contains(Producer.square(at)))
                        network.settled.put(at, new Settled(Integer.parseInt(fields[2]), Float.parseFloat(fields[3]), Float.parseFloat(fields[4])));
                }
                case "W" -> {
                    Position at = Position.parse(fields[1]);
                    var fluids = new HashMap<String, Float>();
                    for (int field = 5; field + 1 < fields.length; field += 2) fluids.put(fields[field], Float.parseFloat(fields[field + 1]));
                    if (network.producers.contains(Producer.square(at)))
                        network.stored.put(at, new Stored(Float.parseFloat(fields[2]), Float.parseFloat(fields[3]), Map.copyOf(fluids),
                            Long.parseLong(fields[4])));
                }
                case "C" -> network.consumption.put(new Thing(Position.parse(fields[1]), fields[3]), Float.parseFloat(fields[2]));
                case "H" -> {
                    network.history = new TreeMap<>();
                    network.suppliedBefore = changes(fields, network.history);
                }
                case "O" -> {
                    network.switches.clear();
                    network.enabledBefore = changes(fields, network.switches);
                }
                default -> throw new IllegalStateException("Unknown line in the state handed over: " + lines[index]);
            }
        }
    }

    /** Reads a line of changes into {@code changes}; whether it was true before the first. */
    private static boolean changes(String[] fields, NavigableMap<Double, Boolean> changes) {
        for (int field = 2; field + 1 < fields.length; field += 2) changes.put(Double.parseDouble(fields[field]), "1".equals(fields[field + 1]));
        return "1".equals(fields[1]);
    }
}
