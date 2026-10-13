package se.krka.kahlua.vm;

/** Synthetic: the walk over a table's entries, as the game's Lua tables give it. */
public interface KahluaTableIterator {
    boolean advance();
    Object getKey();
    Object getValue();
}
