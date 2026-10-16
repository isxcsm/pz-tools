package zombie.iso;

/** Synthetic: a table from numbers to values that is built once and read without allocating (open addressing). */
final class LongTable<V> {
    private long[] keys = new long[16];
    private Object[] values = new Object[16];
    private int count;

    @SuppressWarnings("unchecked")
    V get(long key) {
        int mask = keys.length - 1;
        for (int at = slot(key, mask);; at = at + 1 & mask) {
            Object found = values[at];
            if (found == null) return null;
            if (keys[at] == key) return (V)found;
        }
    }

    void put(long key, V value) {
        if ((count + 1) * 2 > keys.length) grow();
        int mask = keys.length - 1;
        int at = slot(key, mask);
        while (values[at] != null && keys[at] != key) at = at + 1 & mask;
        if (values[at] == null) count++;
        keys[at] = key;
        values[at] = value;
    }

    @SuppressWarnings("unchecked")
    private void grow() {
        long[] oldKeys = keys;
        Object[] oldValues = values;
        keys = new long[oldKeys.length * 2];
        values = new Object[oldValues.length * 2];
        count = 0;
        for (int at = 0; at < oldKeys.length; at++) if (oldValues[at] != null) put(oldKeys[at], (V)oldValues[at]);
    }

    private static int slot(long key, int mask) {
        long mixed = key * 0x9E3779B97F4A7C15L;
        return (int)(mixed ^ mixed >>> 29) & mask;
    }
}
