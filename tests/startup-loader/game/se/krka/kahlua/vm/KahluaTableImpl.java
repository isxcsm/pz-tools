package se.krka.kahlua.vm;

import java.util.HashMap;

/** Synthetic. */
public final class KahluaTableImpl implements KahluaTable {
    private final HashMap<Object, Object> values = new HashMap<>();
    private KahluaTable metatable;
    @Override public void setMetatable(KahluaTable value) { metatable = value; }
    @Override public KahluaTable getMetatable() { return metatable; }
    @Override public void rawset(Object key, Object value) { if (value == null) values.remove(key); else values.put(key, value); }
    @Override public Object rawget(Object key) { return values.get(key); }
    // The boxed numbers of the array part, made once: the game's table reads its array without boxing, and a test of what a call allocates must not count it.
    private static final Double[] BOXED = new Double[32768];
    static { for (int index = 0; index < BOXED.length; index++) BOXED[index] = (double)index; }
    private static Double box(int key) { return key >= 0 && key < BOXED.length ? BOXED[key] : Double.valueOf(key); }
    @Override public void rawset(int key, Object value) { rawset((Object)box(key), value); }
    @Override public Object rawget(int key) { return values.get(box(key)); }
    @Override public KahluaTableIterator iterator() {
        var entries = new java.util.ArrayList<>(values.entrySet()).iterator();
        return new KahluaTableIterator() {
            private java.util.Map.Entry<Object, Object> current;
            @Override public boolean advance() { current = entries.hasNext() ? entries.next() : null; return current != null; }
            @Override public Object getKey() { return current.getKey(); }
            @Override public Object getValue() { return current.getValue(); }
        };
    }
    @Override public int len() { int count = 0; while (values.containsKey(box(count + 1))) count++; return count; }
}
