package pztools.bridge.runtime.api;

import java.lang.reflect.*;
import java.util.*;
import pztools.bridge.runtime.api.Network.Position;

/**
 * The fluid that mods drew from and filled into water producers whose squares were not loaded, owed to those squares
 * until they load (docs/design/extension-api.md, "Draw and fill"). Kept by square for the world, not in a network: a
 * network defined again, or one whose producers change, owes the same. The world saves it in the game's global ModData
 * under {@link #KEY}; {@link WaterGrid} applies a square's changes as it loads.
 */
final class PendingFluids {
    /** The global ModData table: {@code next}, the next sequence number, and {@code deltas}, a list of the changes. */
    static final String KEY = "PZToolsPendingFluids";

    /**
     * One change owed to a square: litres to add (below 0 to draw), the game's name of the fluid a fill adds, and a
     * sequence number, which grows with each change and with the clock.
     */
    record Delta(long sequence, double litres, String fluid) { }

    private final Kahlua lua;
    private final Method get, getOrCreate;
    // The ModData table the changes were read from: another one means another world (or the same one loaded again).
    private Object table;
    private boolean read;
    private final Map<Position, List<Delta>> deltas = new LinkedHashMap<>();
    // The squares owed something, for the water hooks, which ask on the fixture's thread.
    private volatile Set<Position> squares = Set.of();
    private long next;

    PendingFluids(ClassLoader loader, Kahlua lua) throws ReflectiveOperationException {
        this.lua = lua;
        Class<?> modData = Class.forName("zombie.world.moddata.ModData", false, loader);
        get = modData.getMethod("get", String.class);
        getOrCreate = modData.getMethod("getOrCreate", String.class);
    }

    /** Reads the changes again when the world's ModData is another table than they were read from. */
    void refresh() throws ReflectiveOperationException {
        Object current = get.invoke(null, KEY);
        if (read && current == table) return;
        read = true;
        table = current;
        deltas.clear();
        next = 0;
        if (current != null) {
            if (lua.get(current, "next") instanceof Double number) next = number.longValue();
            Object list = lua.get(current, "deltas");
            for (int index = 1; lua.isTable(list); index++) {
                Object item = lua.get(list, (double)index);
                if (item == null) break;
                // A table any Lua mod can reach: what is not a change as this class writes it is left out.
                if (!lua.isTable(item) || !(lua.get(item, "x") instanceof Double x) || !(lua.get(item, "y") instanceof Double y)
                        || !(lua.get(item, "z") instanceof Double z) || !(lua.get(item, "sequence") instanceof Double sequence)
                        || !(lua.get(item, "litres") instanceof Double litres)) continue;
                Object fluid = lua.get(item, "fluid");
                if (litres > 0 && !(fluid instanceof String)) continue;
                deltas.computeIfAbsent(new Position(x.intValue(), y.intValue(), z.intValue()), at -> new ArrayList<>())
                    .add(new Delta(sequence.longValue(), litres, litres > 0 ? (String)fluid : null));
                next = Math.max(next, sequence.longValue() + 1);
            }
        }
        for (List<Delta> owed : deltas.values()) owed.sort(Comparator.comparingLong(Delta::sequence));
        squares = Set.copyOf(deltas.keySet());
    }

    boolean isEmpty() { return deltas.isEmpty(); }

    /** Whether the square is owed something; on any thread. */
    boolean owed(Position at) { return squares.contains(at); }

    /** The squares owed something, in the order they were first owed. */
    List<Position> squares() { return List.copyOf(deltas.keySet()); }

    /** What the square is owed, in order. */
    List<Delta> at(Position at) { return deltas.getOrDefault(at, List.of()); }

    /** The litres the square is owed, all its changes added up (below 0 for draws). */
    double total(Position at) {
        double result = 0;
        for (Delta delta : at(at)) result += delta.litres();
        return result;
    }

    /** Owes the square a change; {@code fluid} names what a fill adds. */
    void add(Position at, double litres, String fluid) throws ReflectiveOperationException {
        refresh();
        // With the clock too: a world loaded again after a crash may have kept an older next, but its squares the
        // numbers of the changes they took (see WaterGrid.apply).
        long sequence = Math.max(next, System.currentTimeMillis());
        next = sequence + 1;
        deltas.computeIfAbsent(at, unused -> new ArrayList<>()).add(new Delta(sequence, litres, litres > 0 ? fluid : null));
        save();
    }

    /** The square took what it was owed, or can no longer. */
    void remove(Position at) throws ReflectiveOperationException {
        if (deltas.remove(at) != null) save();
    }

    private void save() throws ReflectiveOperationException {
        Object current = getOrCreate.invoke(null, KEY);
        var list = new ArrayList<Object>();
        for (var entry : deltas.entrySet())
            for (Delta delta : entry.getValue()) {
                Object item = lua.table();
                Position at = entry.getKey();
                lua.set(item, "x", (double)at.x()); lua.set(item, "y", (double)at.y()); lua.set(item, "z", (double)at.z());
                lua.set(item, "sequence", (double)delta.sequence());
                lua.set(item, "litres", delta.litres());
                if (delta.fluid() != null) lua.set(item, "fluid", delta.fluid());
                list.add(item);
            }
        lua.set(current, "next", (double)next);
        lua.set(current, "deltas", lua.list(list));
        table = current;
        squares = Set.copyOf(deltas.keySet());
    }
}
