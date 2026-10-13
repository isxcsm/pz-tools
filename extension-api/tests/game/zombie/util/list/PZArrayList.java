package zombie.util.list;

import java.util.AbstractList;
import java.util.ArrayList;
import java.util.Iterator;

/** Synthetic: like the game's, a java.util.List read by index, whose iterator throws. */
public final class PZArrayList<E> extends AbstractList<E> {
    private final ArrayList<E> items = new ArrayList<>();
    @Override public E get(int index) { return items.get(index); }
    @Override public int size() { return items.size(); }
    @Override public boolean add(E item) { return items.add(item); }
    @Override public void clear() { items.clear(); }
    @Override public E remove(int index) { return items.remove(index); }
    @Override public boolean remove(Object item) { return items.remove(item); }
    @Override public Iterator<E> iterator() { throw new UnsupportedOperationException(); }
}
