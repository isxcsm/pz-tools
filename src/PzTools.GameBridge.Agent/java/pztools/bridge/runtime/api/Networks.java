package pztools.bridge.runtime.api;

import java.util.*;
import pztools.bridge.ApiHooks;
import pztools.bridge.runtime.api.Network.Position;
import pztools.bridge.runtime.api.Network.Thing;

/**
 * {@code PZToolsAPI.networks}: the networks the mods define (docs/design/extension-api.md, "Networks"). Each belongs to
 * the mod whose handle defined it, and only that mod changes it. The definitions are kept in the API table's metatable,
 * so that a newer payload takes them over, and are gone with the world they were made in.
 */
final class Networks {
    private static final String AREA = "PZToolsAPI.networks.";
    private static final String NAME = "[A-Za-z0-9_.-]{1,64}";
    private static final int MAX_SPRITE = 256;
    // The key in the API's metatable, and the version of the text kept there.
    private static final String MIRROR = "networks", FORMAT = "pztools-networks 1";
    // The most a load factor multiplies a load by.
    private static final double MAX_LOAD_FACTOR = 100;

    /** The mod a handle belongs to, or null when the value is not one of the API's handles. */
    @FunctionalInterface interface Owners { String of(Object handle) throws ReflectiveOperationException; }

    private final Kahlua lua;
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

    Networks(Kahlua lua, Buildings buildings, ClassLoader game, Object meta, Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.buildings = buildings;
        this.meta = meta;
        this.owners = owners;
        members = new Members(game, buildings, networks);
        grid = new PowerGrid(game, members);
        try { water = new WaterGrid(game, members); }
        catch (LinkageError olderBootstrap) { water = null; }
        load(lua.get(meta, MIRROR));
        changed();
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

    /** Sets this area's functions into its table, replacing those of an earlier payload. */
    void register(Object table) throws ReflectiveOperationException {
        grid.addEvent();
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
            saved();
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
            saved();
            return new Object[] { true };
        });
        function(table, "setProducers", (call, arguments) -> {
            Network network = mine(arguments, call);
            Object list = arguments.length > 2 ? arguments[2] : null;
            if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": producers must be a list of squares");
            if (network.parent != null && lua.get(list, 1.0) != null)
                throw new IllegalArgumentException(call + ": " + network.id + " is a child network; its parent's producers supply it");
            var producers = new ArrayList<Position>();
            for (int index = 1;; index++) {
                Object item = lua.get(list, (double)index);
                if (item == null) break;
                Position at = position(item, call, "producers[" + index + "]");
                if (producers.contains(at)) throw new IllegalArgumentException(call + ": " + at + " is listed twice");
                for (Network other : networks.values())
                    if (other != network && other.producers.contains(at))
                        throw new IllegalArgumentException(call + ": " + at + " is a producer of the network " + other.id);
                producers.add(at);
            }
            network.producers.clear();
            network.producers.addAll(producers);
            network.seen.keySet().retainAll(producers);
            network.settled.keySet().retainAll(producers);
            network.stored.keySet().retainAll(producers);
            saved();
            return new Object[0];
        });
        function(table, "setParent", (call, arguments) -> {
            Network network = mine(arguments, call);
            Object parentId = arguments.length > 2 ? arguments[2] : null;
            if (parentId == null) { network.parent = null; saved(); return new Object[0]; }
            if (!(parentId instanceof String text)) throw new IllegalArgumentException(call + ": parent must be a network id or nil");
            Network parent = networks.get(text);
            if (parent == null) throw new IllegalArgumentException(call + ": there is no network " + text);
            own(parent, network.owner, call);
            if (!parent.utility.equals(network.utility))
                throw new IllegalArgumentException(call + ": " + text + " carries " + parent.utility + ", not " + network.utility);
            if (!network.producers.isEmpty())
                throw new IllegalArgumentException(call + ": " + network.id + " has producers; a child network has none");
            for (Network above = parent; above != null; above = above.parent == null ? null : networks.get(above.parent))
                if (above == network) throw new IllegalArgumentException(call + ": " + text + " is a child of " + network.id);
            network.parent = parent.id;
            saved();
            return new Object[0];
        });
        function(table, "setEnabled", (call, arguments) -> {
            Network network = mine(arguments, call);
            if (!(arguments.length > 2 && arguments[2] instanceof Boolean on))
                throw new IllegalArgumentException(call + ": on must be true or false");
            if (network.enabled != on) {
                network.enabled = on;
                grid.switched(network);
                saved();
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
                saved();
            }
            return new Object[0];
        });
        function(table, "addBuilding", (call, arguments) -> {
            Network network = mine(arguments, call);
            Position at = square(arguments, 2, call);
            if (!network.buildings.contains(at)) network.buildings.add(at);
            saved();
            return new Object[] { buildings.buildingAt(at.x(), at.y(), at.z()) != null };
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
            network.buildings.removeAll(named);
            saved();
            return new Object[] { !named.isEmpty() };
        });
        function(table, "exclude", (call, arguments) -> {
            Network network = mine(arguments, call);
            Thing thing = thing(arguments, call);
            network.included.remove(thing);
            network.excluded.add(thing);
            consumersChanged(network, thing);
            saved();
            return new Object[0];
        });
        function(table, "include", (call, arguments) -> {
            Network network = mine(arguments, call);
            Thing thing = thing(arguments, call);
            network.excluded.remove(thing);
            network.included.add(thing);
            consumersChanged(network, thing);
            saved();
            return new Object[0];
        });
        function(table, "reset", (call, arguments) -> {
            Network network = mine(arguments, call);
            Thing thing = thing(arguments, call);
            network.excluded.remove(thing);
            network.included.remove(thing);
            consumersChanged(network, thing);
            saved();
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
            if (network == null || members.cell() == null) return new Object[] { null, false };
            boolean[] complete = { true };
            var result = new ArrayList<Object>();
            var filter = WaterGrid.UTILITY.equals(network.utility) ? Members.WATER : Members.POWER;
            for (var consumer : members.consumers(network, filter, complete)) result.add(buildings.entry(consumer));
            return new Object[] { lua.list(result), complete[0] };
        });
    }

    /** A power network's state: its load, how long its fuel lasts, and its producers as last seen. */
    private void power(Object result, Network network) throws ReflectiveOperationException {
        lua.set(result, "load", (double)network.total);
        lua.set(result, "ownLoad", (double)network.load);
        lua.set(result, "loadFactor", (double)network.loadFactor);
        lua.set(result, "complete", network.loadComplete);
        if (network.inUse != null) lua.set(result, "producer", square(network.inUse));
        Double hoursLeft = grid.hoursLeft(network);
        if (hoursLeft != null) lua.set(result, "hoursLeft", hoursLeft);
        var producers = new ArrayList<Object>();
        for (Position at : network.producers) {
            Object entry = square(at);
            var seen = network.seen.get(at);
            if (seen != null) {
                lua.set(entry, "running", seen.activated());
                lua.set(entry, "fuel", (double)seen.fuel());
                lua.set(entry, "condition", (double)seen.condition());
            }
            producers.add(entry);
        }
        lua.set(result, "producers", lua.list(producers));
    }

    /**
     * A water network's state: what its producers hold, as last seen; for a child, those of the network at the top of
     * its parents.
     */
    private void water(Object result, Network network) throws ReflectiveOperationException {
        Network root = members.root(network);
        double held = 0, most = 0;
        var producers = new ArrayList<Object>();
        for (Position at : root == null ? List.<Position>of() : root.producers) {
            Object entry = square(at);
            var stored = root.stored.get(at);
            if (stored != null) {
                lua.set(entry, "amount", (double)stored.amount());
                lua.set(entry, "capacity", (double)stored.capacity());
                held += stored.amount();
                most += stored.capacity();
            }
            if (network == root) producers.add(entry);
        }
        lua.set(result, "amount", held);
        lua.set(result, "capacity", most);
        lua.set(result, "producers", lua.list(producers));
    }

    /** {@code handle:clear()}: removes everything the mod defined. */
    void clear(String owner) throws ReflectiveOperationException {
        if (networks.values().removeIf(network -> network.owner.equals(owner))) saved();
    }

    private void detachChildren(String id) {
        for (Network child : networks.values()) if (id.equals(child.parent)) child.parent = null;
    }

    /** Each frame, on the game's thread. */
    void frame() {
        try {
            Object cell = members.cell();
            // The world the networks were defined in was left; the mods define them again in the next one.
            if (world != null && cell != world && !networks.isEmpty()) { networks.clear(); saved(); }
            world = cell;
            if (cell == null) return;
            grid.frame(cell);
            if (water != null) water.frame(cell);
        } catch (Throwable failure) {
            // Once: a fault that recurs each frame must not flood the game's log. The hooks keep answering.
            if (!reported) System.err.println("[PzTools API] networks: " + failure);
            reported = true;
        }
    }

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> body.call(call, arguments)));
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
        return owner;
    }

    private static String id(Object[] arguments, String call) {
        String id = Arguments.string(arguments, 1, call, "id");
        if (!id.matches(NAME)) throw new IllegalArgumentException(call + ": id must be 1 to 64 letters, digits, '_', '.' or '-'");
        return id;
    }

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

    /** The network's consumers changed: its load is worked out again, without what was last seen of the object. */
    private static void consumersChanged(Network network, Thing thing) {
        var consumption = new LinkedHashMap<>(network.consumption);
        consumption.remove(thing);
        network.consumption = consumption;
        network.loadChanged = true;
    }

    /** Keeps the definitions where a newer payload finds them, and works the networks out again. */
    private void saved() throws ReflectiveOperationException {
        var text = new StringBuilder(FORMAT).append('\n');
        for (Network network : networks.values()) {
            text.append("N\t").append(network.id).append('\t').append(network.owner).append('\t')
                .append(network.utility).append('\t').append(network.policy).append('\t')
                .append(network.parent == null ? "" : network.parent).append('\t')
                .append(network.enabled ? "" : "off").append('\t')
                .append(network.loadFactor == 1f ? "" : Float.toString(network.loadFactor)).append('\n');
            for (Position at : network.producers) text.append("P\t").append(at).append('\n');
            for (Position at : network.buildings) text.append("B\t").append(at).append('\n');
            for (Thing thing : network.excluded) text.append("X\t").append(thing.at()).append('\t').append(thing.sprite()).append('\n');
            for (Thing thing : network.included) text.append("I\t").append(thing.at()).append('\t').append(thing.sprite()).append('\n');
        }
        lua.set(meta, MIRROR, text.toString());
        changed();
    }

    /** Works the networks out again: the hooks know the definitions at once, the next frame the rest. */
    private void changed() throws ReflectiveOperationException {
        grid.changed();
        if (water != null) water.changed();
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
                }
                case "P" -> network.producers.add(Position.parse(fields[1]));
                case "B" -> network.buildings.add(Position.parse(fields[1]));
                case "X" -> network.excluded.add(new Thing(Position.parse(fields[1]), fields[2]));
                case "I" -> network.included.add(new Thing(Position.parse(fields[1]), fields[2]));
                default -> throw new IllegalStateException("Unknown line in the kept networks: " + lines[index]);
            }
        }
    }
}
