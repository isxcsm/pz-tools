package zombie.Lua;

import java.util.ArrayList;
import java.util.List;

/** Synthetic: the events added and the ones raised, for the test to read. */
public final class LuaEventManager {
    public static final List<String> added = new ArrayList<>();
    public static final List<List<Object>> raised = new ArrayList<>();
    public static Object AddEvent(String name) {
        if (!added.contains(name)) added.add(name);
        return null;
    }
    public static void triggerEvent(String name, Object first, Object second) {
        raised.add(List.of(name, first, second));
    }
    public static void triggerEvent(String name, Object first, Object second, Object third) {
        raised.add(List.of(name, first, second, third));
    }
}
