package pzext.api;

import java.lang.reflect.*;
import java.util.*;
import pzext.api.Network.Position;

/**
 * The fluid that mods drew from and filled into water producers whose squares were not loaded, owed to those squares
 * until they load (docs/design.md, "Draw and fill"). Kept by square for the world, not in a network: a
 * network defined again, or one whose producers change, owes the same. The world saves it in the game's global ModData
 * under {@link #KEY}; {@link WaterGrid} applies a square's changes as it loads.
 * <p>
 * A draw owed right after a draw to the same square adds to it, and so does a fill of one fluid after a fill of the
 * same: the square takes them as one change, exactly as it would take them one after the other. The containers on a
 * square give a draw by levelling their shares of their capacities, from the fullest down (WaterGrid.level), and a
 * second draw levels on from where the first stopped, so the two take what one draw of both would; a fill levels the
 * room left the same way, and each container gives or takes every fluid in proportion. So a mod that draws every few
 * minutes from a producer far away owes one change, not one per draw.
 */
final class PendingFluids {
    /** The global ModData table: {@code next}, the next sequence number, and {@code deltas}, a list of the changes. */
    static final String KEY = "PZExtPendingFluids";

    /**
     * One change owed to a square: litres to add (below 0 to draw), the game's name of the fluid a fill adds, and a
     * sequence number, which grows with each change and with the clock.
     */
    record Delta(long sequence, double litres, String fluid) { }

    private final Kahlua lua;
    private final Method get, getOrCreate;
    // The ModData table the changes were read from: another one means another world (or the same one loaded again).
    private Object table;
    private boolean read, reread;
    private final Map<Position, List<Delta>> deltas = new LinkedHashMap<>();
    // The squares owed something, for the water hooks, which ask on the fixture's thread.
    private volatile Set<Position> squares = Set.of();
    // The next sequence number: past every one given, read or seen taken in this game, never lower (see add).
    private long next;
    // The lowest sequence number given since the changes were read. One below it was read from the ModData, and its
    // square may have taken it already (a world that stopped before its ModData was saved): nothing adds to it.
    private long fresh = Long.MAX_VALUE;
    // The list of changes in the ModData table as this class last wrote it, its length, and the item of each square's
    // last change: a new change is added to it, and one that adds to the last changes that item alone.
    private Object list;
    private int length;
    private final Map<Position, Object> lastItems = new HashMap<>();

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
        reread = true;
        table = current;
        deltas.clear();
        if (current != null) {
            if (lua.get(current, "next") instanceof Double number) next = Math.max(next, number.longValue());
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
        fresh = next;
        // Written whole at the next change, without what was not a change.
        list = null;
    }

    /** Whether the changes were read again (from another table) since this was last asked; asked, it is cleared. */
    boolean reread() {
        boolean result = reread;
        reread = false;
        return result;
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

    /**
     * Owes the square a change; {@code fluid} names what a fill adds. A draw right after a draw owed to the square, or a
     * fill after a fill of the same fluid, adds to it (see the class).
     */
    void add(Position at, double litres, String fluid) throws ReflectiveOperationException {
        refresh();
        // Past every number given, read or seen taken in this game, whatever the ModData read says; and with the clock
        // too, for a game started again: a world that stopped before its ModData was saved may have kept an older next,
        // but its squares the numbers of the changes they took (see WaterGrid.apply).
        long sequence = Math.max(next, System.currentTimeMillis());
        next = sequence + 1;
        List<Delta> owed = deltas.computeIfAbsent(at, unused -> new ArrayList<>());
        Delta last = owed.isEmpty() ? null : owed.get(owed.size() - 1);
        boolean adds = last != null && last.sequence() >= fresh
            && (litres < 0 ? last.litres() < 0 : last.litres() > 0 && last.fluid().equals(fluid));
        // The sum takes the later number: the square has taken neither.
        Delta delta = new Delta(sequence, adds ? last.litres() + litres : litres, litres > 0 ? fluid : null);
        if (adds) owed.set(owed.size() - 1, delta);
        else owed.add(delta);
        write(at, delta, adds);
    }

    /** A square was seen to have taken the change of that number: later ones are numbered past it. */
    void numberPast(long sequence) { next = Math.max(next, sequence + 1); }

    /** The next sequence number, for a newer API to go on from (see Networks.handover). */
    long next() { return next; }

    /** The square took what it was owed, or can no longer. */
    void remove(Position at) throws ReflectiveOperationException {
        if (deltas.remove(at) != null) save();
    }

    /** Writes one change to the ModData table: into its list as this class last wrote it, or the list whole. */
    private void write(Position at, Delta delta, boolean adds) throws ReflectiveOperationException {
        Object current = getOrCreate.invoke(null, KEY), item = adds ? lastItems.get(at) : null;
        if (current != table || list == null || lua.get(current, "deltas") != list || adds && item == null) { save(); return; }
        if (adds) {
            lua.set(item, "sequence", (double)delta.sequence());
            lua.set(item, "litres", delta.litres());
        } else {
            item = item(at, delta);
            lua.set(list, (double)++length, item);
            lastItems.put(at, item);
            if (!squares.contains(at)) squares = Set.copyOf(deltas.keySet());
        }
        lua.set(current, "next", (double)next);
    }

    private void save() throws ReflectiveOperationException {
        Object current = getOrCreate.invoke(null, KEY);
        var items = new ArrayList<Object>();
        lastItems.clear();
        for (var entry : deltas.entrySet())
            for (Delta delta : entry.getValue()) {
                Object item = item(entry.getKey(), delta);
                items.add(item);
                lastItems.put(entry.getKey(), item);
            }
        list = lua.list(items);
        length = items.size();
        lua.set(current, "next", (double)next);
        lua.set(current, "deltas", list);
        table = current;
        squares = Set.copyOf(deltas.keySet());
    }

    private Object item(Position at, Delta delta) throws ReflectiveOperationException {
        Object item = lua.table();
        lua.set(item, "x", (double)at.x()); lua.set(item, "y", (double)at.y()); lua.set(item, "z", (double)at.z());
        lua.set(item, "sequence", (double)delta.sequence());
        lua.set(item, "litres", delta.litres());
        if (delta.fluid() != null) lua.set(item, "fluid", delta.fluid());
        return item;
    }
}
