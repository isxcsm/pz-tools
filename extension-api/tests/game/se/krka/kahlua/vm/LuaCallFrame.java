package se.krka.kahlua.vm;

import java.util.ArrayList;
import java.util.List;

/** Synthetic: one call's arguments, and the results the function pushes. */
public final class LuaCallFrame {
    private final Object[] arguments;
    public final List<Object> results = new ArrayList<>();
    public LuaCallFrame(Object... arguments) { this.arguments = arguments; }
    public Object get(int index) { return arguments[index]; }
    public int push(Object value) { results.add(value); return 1; }
    public int pushNil() { results.add(null); return 1; }
}
