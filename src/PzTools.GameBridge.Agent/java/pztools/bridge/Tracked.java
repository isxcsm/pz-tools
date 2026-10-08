package pztools.bridge;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.function.Predicate;
import java.util.function.UnaryOperator;

/**
 * A game list that tells the extension API when it changes: {@code ItemContainer.items} (kind {@link #ITEMS}) and the
 * list of {@code WornItems} (kind {@link #WORN}). The hooks put one in the place of the game's {@code ArrayList} where
 * the game makes it (the game's own code is not changed otherwise), so that whatever the game or a mod does with the
 * list, through the container's methods or {@code getItems()}, goes through the methods below. It is an ArrayList and
 * behaves as one in every other way.
 *
 * <p>{@link #version} counts the changes. {@link #kept} is the API's own: what it keeps about the list, null until it
 * first asks (a list nobody asked about costs a counter and a null test per change). The API is told of each change
 * <i>after</i> the list has made it: an item added or removed, or {@code changed} for whatever it cannot follow
 * item by item ({@code removeIf}, {@code removeAll}, {@code retainAll}, {@code replaceAll}, {@code removeRange}).
 * Changing the order ({@code sort}) tells nothing: the API does not read the order.
 */
public final class Tracked extends ArrayList<Object> {
    private static final long serialVersionUID = 1L;

    /** The kinds: a container's items, a character's worn items. */
    public static final int ITEMS = 0, WORN = 1;

    /** Which list this is, and what holds it (the ItemContainer or the WornItems). */
    public final int kind;
    public final transient Object owner;
    /** The API's: null until it asks. Set and read under the API's own lock. */
    public transient volatile Object kept;
    /** How many times the list changed; read without a lock, by anyone. */
    public transient int version;

    public Tracked(int kind, Object owner, Collection<?> initial) {
        super(initial);
        this.kind = kind;
        this.owner = owner;
    }

    private void added(Object item) {
        version++;
        if (kept != null) ApiHooks.itemAdded(this, item);
    }

    private void removed(Object item) {
        version++;
        if (kept != null) ApiHooks.itemRemoved(this, item);
    }

    private void changed() {
        version++;
        if (kept != null) ApiHooks.listChanged(this);
    }

    @Override public boolean add(Object item) {
        super.add(item);
        added(item);
        return true;
    }

    @Override public void add(int index, Object item) {
        super.add(index, item);
        added(item);
    }

    @Override public boolean addAll(Collection<?> items) {
        Object[] all = items.toArray();
        if (all.length == 0) return false;
        super.addAll(java.util.Arrays.asList(all));
        for (Object item : all) added(item);
        return true;
    }

    @Override public boolean addAll(int index, Collection<?> items) {
        Object[] all = items.toArray();
        if (all.length == 0) return false;
        super.addAll(index, java.util.Arrays.asList(all));
        for (Object item : all) added(item);
        return true;
    }

    @Override public Object remove(int index) {
        Object item = super.remove(index);
        removed(item);
        return item;
    }

    /** As ArrayList.remove(Object): the first equal item, which is the one the API is told of. */
    @Override public boolean remove(Object item) {
        int index = indexOf(item);
        if (index < 0) return false;
        remove(index);
        return true;
    }

    @Override public Object set(int index, Object item) {
        Object old = super.set(index, item);
        removed(old);
        added(item);
        return old;
    }

    @Override public void clear() {
        boolean any = !isEmpty();
        super.clear();
        version++;
        if (any && kept != null) ApiHooks.listCleared(this);
    }

    @Override protected void removeRange(int from, int to) {
        super.removeRange(from, to);
        changed();
    }

    @Override public boolean removeAll(Collection<?> items) {
        boolean result = super.removeAll(items);
        if (result) changed();
        return result;
    }

    @Override public boolean retainAll(Collection<?> items) {
        boolean result = super.retainAll(items);
        if (result) changed();
        return result;
    }

    @Override public boolean removeIf(Predicate<? super Object> filter) {
        boolean result = super.removeIf(filter);
        if (result) changed();
        return result;
    }

    @Override public void replaceAll(UnaryOperator<Object> operator) {
        super.replaceAll(operator);
        changed();
    }

    @Override public void sort(Comparator<? super Object> order) {
        super.sort(order);
        version++;
    }

    /** A view that changes the list would escape the methods above: it can be read, not written. */
    @Override public List<Object> subList(int from, int to) {
        return Collections.unmodifiableList(super.subList(from, to));
    }

    /** A copy is an ordinary list: it is not the game's, and nothing follows it. */
    @Override public Object clone() {
        return new ArrayList<>(this);
    }
}
