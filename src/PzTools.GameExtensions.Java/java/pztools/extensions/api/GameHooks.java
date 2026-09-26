package pztools.extensions.api;

import java.util.concurrent.ConcurrentHashMap;

/** Nonthrowing, read-only completion observers. Never a suppression, replacement or global save switch. */
public final class GameHooks {
    public interface Observer {
        default void enter() { }
        default void exit(Throwable failure) { }
        default void error(Throwable failure) { }
    }
    private static final class Registration {
        final Observer observer;
        volatile Throwable failure;
        Registration(Observer observer) { this.observer = observer; }
        void failed(Throwable error) { if (failure == null) failure = error; }
    }
    private static final ConcurrentHashMap<String, Registration> observers = new ConcurrentHashMap<>();
    private GameHooks() { }
    public static void register(String point, Observer observer) {
        if (observers.putIfAbsent(point, new Registration(java.util.Objects.requireNonNull(observer))) != null)
            throw new IllegalStateException("Observation point already owned: " + point);
    }
    public static void unregister(String point, Observer observer) {
        Registration r = observers.get(point);
        if (r != null && r.observer == observer) observers.remove(point, r);
    }
    public static Throwable failure(String point) { Registration r = observers.get(point); return r == null ? null : r.failure; }
    public static void enter(String point) {
        Registration r = observers.get(point);
        if (r != null) try { r.observer.enter(); } catch (Throwable failure) { r.failed(failure); }
    }
    public static void exit(String point, Throwable error) {
        Registration r = observers.get(point);
        if (r != null) try { r.observer.exit(error); } catch (Throwable failure) { r.failed(failure); }
    }
    public static void error(String point, Throwable error) {
        Registration r = observers.get(point);
        if (r != null) try { r.observer.error(error); } catch (Throwable failure) { r.failed(failure); }
    }
}
