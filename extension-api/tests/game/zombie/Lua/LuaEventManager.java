package zombie.Lua;

import java.util.ArrayList;
import java.util.List;

/** Synthetic: the events added and the ones raised, for the test to read. */
public final class LuaEventManager {
    public static final List<String> added = new ArrayList<>();
    public static final List<List<Object>> raised = new ArrayList<>();
    /** The thread that raised the last event. */
    public static volatile Thread lastThread;
    /** Told of each event as it is raised (null for none), as a mod's handler would be. */
    public static java.util.function.Consumer<List<Object>> listener;
    public static Object AddEvent(String name) {
        if (!added.contains(name)) added.add(name);
        return null;
    }
    public static void triggerEvent(String name, Object first) {
        lastThread = Thread.currentThread();
        raised.add(List.of(name, first));
    }
    public static void triggerEvent(String name, Object first, Object second) {
        lastThread = Thread.currentThread();
        raised.add(List.of(name, first, second));
        if (listener != null) listener.accept(raised.get(raised.size() - 1));
    }
    public static void triggerEvent(String name, Object first, Object second, Object third) {
        lastThread = Thread.currentThread();
        raised.add(List.of(name, first, second, third));
        if (listener != null) listener.accept(raised.get(raised.size() - 1));
    }
    public static void triggerEvent(String name, Object first, Object second, Object third, Object fourth) {
        lastThread = Thread.currentThread();
        raised.add(java.util.Arrays.asList(name, first, second, third, fourth));
    }
    public static void triggerEvent(String name, Object first, Object second, Object third, Object fourth, Object fifth, Object sixth) {
        lastThread = Thread.currentThread();
        raised.add(java.util.Arrays.asList(name, first, second, third, fourth, fifth, sixth));
    }
}
