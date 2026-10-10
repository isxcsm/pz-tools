package se.krka.kahlua.integration;

import java.util.ArrayList;
import java.util.List;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaCallFrame;

/**
 * Synthetic: how the game calls a Lua function from Java. The results are Lua's: {@code true} and what the function returned, or
 * {@code false} and the error (the function that throws).
 */
public class LuaCaller {
    /** The functions called, with their arguments, for the test to read. */
    public static final List<List<Object>> calls = new ArrayList<>();

    public Object[] pcall(KahluaThread thread, Object function, Object... arguments) {
        var all = new ArrayList<Object>();
        all.add(function);
        if (arguments != null) for (Object argument : arguments) all.add(argument);
        calls.add(all);
        var frame = new LuaCallFrame(arguments == null ? new Object[0] : arguments);
        try {
            ((JavaFunction)function).call(frame, arguments == null ? 0 : arguments.length);
        } catch (RuntimeException failure) {
            return new Object[] { Boolean.FALSE, failure.getMessage() };
        }
        var results = new ArrayList<Object>();
        results.add(Boolean.TRUE);
        results.addAll(frame.results);
        return results.toArray();
    }
}
