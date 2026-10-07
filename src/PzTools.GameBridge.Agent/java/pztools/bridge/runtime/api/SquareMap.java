package pztools.bridge.runtime.api;

import java.util.Map;
import pztools.bridge.runtime.api.Network.Position;

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

    SquareMap(Map<Position, Long> entries) {
        size = entries.size();
        int capacity = Integer.highestOneBit(Math.max(1, size) * 2 - 1) << 1;
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

    boolean isEmpty() { return size == 0; }

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

    private int slot(long key, int z) {
        long mixed = (key ^ z * 0x9E3779B97F4A7C15L) * 0xBF58476D1CE4E5B9L;
        return (int)(mixed ^ mixed >>> 31) & mask;
    }
}
