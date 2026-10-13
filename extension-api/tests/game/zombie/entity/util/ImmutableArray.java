package zombie.entity.util;

import java.util.List;

/** Synthetic: a read-only view of a list, as the game's buckets give their entities. */
public class ImmutableArray<T> {
    private final List<T> items;
    public ImmutableArray(List<T> items) { this.items = items; }
    public int size() { return items.size(); }
    public T get(int index) { return items.get(index); }
}
