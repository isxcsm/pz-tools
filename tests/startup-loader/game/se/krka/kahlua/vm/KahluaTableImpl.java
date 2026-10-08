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
    @Override public KahluaTableIterator iterator() {
        var entries = new java.util.ArrayList<>(values.entrySet()).iterator();
        return new KahluaTableIterator() {
            private java.util.Map.Entry<Object, Object> current;
            @Override public boolean advance() { current = entries.hasNext() ? entries.next() : null; return current != null; }
            @Override public Object getKey() { return current.getKey(); }
            @Override public Object getValue() { return current.getValue(); }
        };
    }
    @Override public int len() { int count = 0; while (values.containsKey((double)(count + 1))) count++; return count; }
}
