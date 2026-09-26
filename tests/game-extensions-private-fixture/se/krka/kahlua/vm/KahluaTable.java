package se.krka.kahlua.vm;
/** Test-only UI state. Saving must neither inspect nor reset this table. */
public final class KahluaTable {
    private final java.util.Map<Object, Object> entries = new java.util.HashMap<>();
    public Object rawget(Object key) { return entries.get(key); }
    public void rawset(Object key, Object value) { if (value == null) entries.remove(key); else entries.put(key, value); }
}