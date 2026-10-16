package zombie.iso;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.function.Function;

/**
 * Synthetic: a map by position, which tests read and change by the text key ("x,y,z" for a square, "wx,wy" for a chunk)
 * and the cell asks by numbers, without building a key: the text keys are kept in the map itself, the numbers in a table
 * beside it. Only the changes tests make are supported (put, remove, putAll, clear, computeIfAbsent).
 */
public final class PositionMap<V> extends HashMap<String, V> {
    // Open addressing on the packed position; an empty slot has no value.
    private long[] keys = new long[64];
    private Object[] values = new Object[64];
    private int count;

    /** A square's position as one number: x and y in 26 bits each, z in 12. */
    static long pack(int x, int y, int z) { return (long)(x & 0x3FFFFFF) << 38 | (long)(y & 0x3FFFFFF) << 12 | z & 0xFFF; }

    /** A chunk's position as one number. */
    static long pack(int wx, int wy) { return (long)wx << 32 | wy & 0xFFFFFFFFL; }

    private static long parse(String key) {
        String[] parts = key.split(",");
        if (parts.length == 3) return pack(Integer.parseInt(parts[0]), Integer.parseInt(parts[1]), Integer.parseInt(parts[2]));
        if (parts.length == 2) return pack(Integer.parseInt(parts[0]), Integer.parseInt(parts[1]));
        throw new IllegalArgumentException("Not a position: " + key);
    }

    private static int slot(long key, int mask) {
        long mixed = key * 0x9E3779B97F4A7C15L;
        return (int)(mixed ^ mixed >>> 29) & mask;
    }

    @SuppressWarnings("unchecked")
    V at(long key) {
        int mask = keys.length - 1;
        for (int at = slot(key, mask);; at = at + 1 & mask) {
            Object found = values[at];
            if (found == null) return null;
            if (keys[at] == key) return (V)found;
        }
    }

    public V at(int x, int y, int z) { return at(pack(x, y, z)); }

    public V at(int wx, int wy) { return at(pack(wx, wy)); }

    private void store(long key, V value) {
        if ((count + 1) * 2 > keys.length) grow();
        int mask = keys.length - 1;
        int at = slot(key, mask);
        while (values[at] != null && keys[at] != key) at = at + 1 & mask;
        if (values[at] == null) count++;
        keys[at] = key;
        values[at] = value;
    }

    private void grow() {
        long[] oldKeys = keys;
        Object[] oldValues = values;
        keys = new long[oldKeys.length * 2];
        values = new Object[oldValues.length * 2];
        count = 0;
        for (int at = 0; at < oldKeys.length; at++) if (oldValues[at] != null) store(oldKeys[at], cast(oldValues[at]));
    }

    @SuppressWarnings("unchecked")
    private V cast(Object value) { return (V)value; }

    private void erase(long key) {
        int mask = keys.length - 1;
        int at = slot(key, mask);
        while (values[at] != null && keys[at] != key) at = at + 1 & mask;
        if (values[at] == null) return;
        // Backward shift: later entries of the run move into the hole when their home allows.
        values[at] = null;
        count--;
        for (int next = at + 1 & mask; values[next] != null; next = next + 1 & mask) {
            long moved = keys[next];
            Object value = values[next];
            values[next] = null;
            count--;
            store(moved, cast(value));
        }
    }

    @Override public V put(String key, V value) {
        long packed = parse(key);
        V before = super.put(key, value);
        store(packed, value);
        return before;
    }

    @Override public V remove(Object key) {
        V before = super.remove(key);
        if (key instanceof String text) erase(parse(text));
        return before;
    }

    @Override public void clear() {
        super.clear();
        Arrays.fill(values, null);
        count = 0;
    }

    @Override public void putAll(Map<? extends String, ? extends V> all) {
        for (var entry : all.entrySet()) put(entry.getKey(), entry.getValue());
    }

    @Override public V computeIfAbsent(String key, Function<? super String, ? extends V> make) {
        V known = super.get(key);
        if (known != null) return known;
        V made = make.apply(key);
        if (made != null) put(key, made);
        return made;
    }

    @Override public V putIfAbsent(String key, V value) { throw new UnsupportedOperationException(); }
    @Override public V compute(String key, java.util.function.BiFunction<? super String, ? super V, ? extends V> function) { throw new UnsupportedOperationException(); }
    @Override public V computeIfPresent(String key, java.util.function.BiFunction<? super String, ? super V, ? extends V> function) { throw new UnsupportedOperationException(); }
    @Override public V merge(String key, V value, java.util.function.BiFunction<? super V, ? super V, ? extends V> function) { throw new UnsupportedOperationException(); }
    @Override public boolean remove(Object key, Object value) { throw new UnsupportedOperationException(); }
    @Override public V replace(String key, V value) { throw new UnsupportedOperationException(); }
    @Override public boolean replace(String key, V old, V value) { throw new UnsupportedOperationException(); }
    @Override public void replaceAll(java.util.function.BiFunction<? super String, ? super V, ? extends V> function) { throw new UnsupportedOperationException(); }
}
