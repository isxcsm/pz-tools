package pzext.api;

import java.util.Map;
import pzext.api.Network.Position;

/**
 * An immutable map from squares to numbers, for the hooks: read on any thread without allocating, at the cost of a box
 * test and a hash probe, whatever the squares' coordinates and however far apart they are. Its memory follows the
 * number of squares in it. Built on the game's thread.
 */
final class SquareMap {
    static final SquareMap EMPTY = new SquareMap(Map.of());

    // Open addressing: x in the high half of a key and y in the low one, with the level beside it.
    private final long[] keys;
    private final int[] levels;
    private final long[] values;
    private final boolean[] used;
    private final int mask, size;
    // The box around the squares, so that most questions end without a probe.
    private final int minX, minY, minZ, maxX, maxY, maxZ;

    private static int capacityFor(int size) { return Integer.highestOneBit(Math.max(1, size) * 2 - 1) << 1; }

    SquareMap(Map<Position, Long> entries) {
        size = entries.size();
        int capacity = capacityFor(size);
        keys = new long[capacity];
        levels = new int[capacity];
        values = new long[capacity];
        used = new boolean[capacity];
        mask = capacity - 1;
        int lowX = Integer.MAX_VALUE, lowY = Integer.MAX_VALUE, lowZ = Integer.MAX_VALUE;
        int highX = Integer.MIN_VALUE, highY = Integer.MIN_VALUE, highZ = Integer.MIN_VALUE;
        for (var entry : entries.entrySet()) {
            Position at = entry.getKey();
            long key = key(at.x(), at.y());
            int slot = slot(key, at.z());
            while (used[slot]) slot = slot + 1 & mask;
            used[slot] = true;
            keys[slot] = key;
            levels[slot] = at.z();
            values[slot] = entry.getValue();
            lowX = Math.min(lowX, at.x()); lowY = Math.min(lowY, at.y()); lowZ = Math.min(lowZ, at.z());
            highX = Math.max(highX, at.x()); highY = Math.max(highY, at.y()); highZ = Math.max(highZ, at.z());
        }
        minX = lowX; minY = lowY; minZ = lowZ; maxX = highX; maxY = highY; maxZ = highZ;
    }

    /**
     * This map and more squares: a copy of the map's tables with the squares put in (made again, wider, only when they no longer fit), not
     * a map made from every square again. A square the map has already is not among {@code more}.
     */
    SquareMap(SquareMap base, Map<Position, Long> more) {
        size = base.size + more.size();
        int capacity = capacityFor(size);
        if (capacity == base.keys.length) {
            keys = base.keys.clone();
            levels = base.levels.clone();
            values = base.values.clone();
            used = base.used.clone();
        } else {
            keys = new long[capacity];
            levels = new int[capacity];
            values = new long[capacity];
            used = new boolean[capacity];
            for (int slot = 0; slot < base.used.length; slot++) if (base.used[slot]) put(keys, levels, values, used, capacity - 1, base.keys[slot], base.levels[slot], base.values[slot]);
        }
        mask = capacity - 1;
        int lowX = base.minX, lowY = base.minY, lowZ = base.minZ, highX = base.maxX, highY = base.maxY, highZ = base.maxZ;
        for (var entry : more.entrySet()) {
            Position at = entry.getKey();
            put(keys, levels, values, used, mask, key(at.x(), at.y()), at.z(), entry.getValue());
            lowX = Math.min(lowX, at.x()); lowY = Math.min(lowY, at.y()); lowZ = Math.min(lowZ, at.z());
            highX = Math.max(highX, at.x()); highY = Math.max(highY, at.y()); highZ = Math.max(highZ, at.z());
        }
        minX = lowX; minY = lowY; minZ = lowZ; maxX = highX; maxY = highY; maxZ = highZ;
    }

    private static void put(long[] keys, int[] levels, long[] values, boolean[] used, int mask, long key, int z, long value) {
        int slot = slot(key, z, mask);
        while (used[slot]) slot = slot + 1 & mask;
        used[slot] = true;
        keys[slot] = key;
        levels[slot] = z;
        values[slot] = value;
    }

    boolean isEmpty() { return size == 0; }

    int size() { return size; }

    /** What {@link #forEach} gives for each square. */
    @FunctionalInterface interface Visit { void at(int x, int y, int z, long value); }

    /** Every square in the map and its number, in no order. */
    void forEach(Visit visit) {
        for (int slot = 0; slot < used.length; slot++)
            if (used[slot]) visit.at((int)(keys[slot] >> 32), (int)keys[slot], levels[slot], values[slot]);
    }

    /** The number kept for the square, or {@code missing}. */
    long get(int x, int y, int z, long missing) {
        int slot = find(x, y, z);
        return slot < 0 ? missing : values[slot];
    }

    boolean contains(int x, int y, int z) { return find(x, y, z) >= 0; }

    private int find(int x, int y, int z) {
        if (x < minX || x > maxX || y < minY || y > maxY || z < minZ || z > maxZ) return -1;
        long key = key(x, y);
        for (int slot = slot(key, z);; slot = slot + 1 & mask) {
            if (!used[slot]) return -1;
            if (keys[slot] == key && levels[slot] == z) return slot;
        }
    }

    private static long key(int x, int y) { return (long)x << 32 | y & 0xFFFFFFFFL; }

    private int slot(long key, int z) { return slot(key, z, mask); }

    private static int slot(long key, int z, int mask) {
        long mixed = (key ^ z * 0x9E3779B97F4A7C15L) * 0xBF58476D1CE4E5B9L;
        return (int)(mixed ^ mixed >>> 31) & mask;
    }
}
