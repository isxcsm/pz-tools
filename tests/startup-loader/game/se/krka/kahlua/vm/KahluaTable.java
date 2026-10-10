package se.krka.kahlua.vm;

/** Synthetic: the part of the game's Lua table the extension API uses. */
public interface KahluaTable {
    void setMetatable(KahluaTable metatable);
    KahluaTable getMetatable();
    void rawset(Object key, Object value);
    Object rawget(Object key);
    /** The array part by its index (1 up), as the game's has it. */
    void rawset(int key, Object value);
    Object rawget(int key);
    int len();
    KahluaTableIterator iterator();
}
