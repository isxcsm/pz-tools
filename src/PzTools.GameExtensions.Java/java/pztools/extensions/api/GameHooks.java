package pztools.extensions.api;

import java.util.concurrent.ConcurrentHashMap;

/** Stable hook targets visible to game classes. No file/network work or per-call dispatch allocation. */
public final class GameHooks {
    public interface Observer {
        default boolean suppress() { return false; }
        default void enter() { }
        default void exit(Throwable failure) { }
        default void error(Throwable failure) { }
    }
    private static final ConcurrentHashMap<String, Observer> observers = new ConcurrentHashMap<>();
    private GameHooks() { }
    public static void register(String point, Observer observer) {
        if (observers.putIfAbsent(point, observer) != null)
            throw new IllegalStateException("Hook point already owned: " + point);
    }
    public static void unregister(String point, Observer observer) { observers.remove(point, observer); }
    public static boolean suppress(String point) {
        Observer observer = observers.get(point);
        return observer != null && observer.suppress();
    }
    public static void enter(String point) {
        Observer observer = observers.get(point);
        if (observer != null) observer.enter();
    }
    public static void exit(String point, Throwable failure) {
        Observer observer = observers.get(point);
        if (observer != null) observer.exit(failure);
    }
    public static void error(String point, Throwable failure) {
        Observer observer = observers.get(point);
        if (observer != null) observer.error(failure);
    }
}
