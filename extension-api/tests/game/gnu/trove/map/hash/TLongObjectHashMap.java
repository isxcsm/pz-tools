package gnu.trove.map.hash;

import java.util.HashMap;

/** Synthetic: the game's map from a long to an object (the part the API asks). */
public class TLongObjectHashMap<V> {
    private final HashMap<Long, V> map = new HashMap<>();

    public boolean contains(long key) { return map.containsKey(key); }

    public V get(long key) { return map.get(key); }

    public V put(long key, V value) { return map.put(key, value); }

    public V remove(long key) { return map.remove(key); }
}
