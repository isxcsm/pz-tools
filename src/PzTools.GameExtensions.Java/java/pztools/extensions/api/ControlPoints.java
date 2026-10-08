package pztools.extensions.api;

import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * Named points in game code where a module may take a decision over. The module's own bytecode puts a
 * call to {@link #call} or {@link #observe} into a game method, and the module registers a handler for
 * that point while it is active. What the mode, the argument and the outcome mean is a contract between
 * the module and the code it generated; the host knows nothing of it.
 *
 * <p>A call with no handler, a call made on a thread already inside any point's handler, and a call
 * after the handler failed all return 0, which generated code must treat as "run the game's own code".
 * A handler that throws is latched as failed: it is not called again, and {@link #failed} names the
 * point to the host, which then retires the module that owns it.
 */
public final class ControlPoints {
    /** Called on whatever thread runs the game code at the point. */
    @FunctionalInterface public interface Handler {
        /** Throws, or returns 0, only before it has changed any game state: the game's code runs next. */
        int call(Object target, int mode, float argument) throws Exception;
        /** Observation only, never writes game state. A failure latches the point but not the outcome already taken. */
        default void observe(Object target, float first, float second, float third) throws Exception { }
    }
    private static final Pattern ID = Pattern.compile("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*");
    private static final class Registration {
        final String point; final Object owner; final Handler handler;
        final Lease calls = new Lease();
        volatile Throwable failure;
        Registration(String point, Object owner, Handler handler) { this.point = point; this.owner = owner; this.handler = handler; }
        void fail(Throwable problem) {
            if (failure == null) failure = problem;
            calls.close();
        }
    }
    private static final ConcurrentHashMap<String, Registration> points = new ConcurrentHashMap<>();
    private static final ThreadLocal<Boolean> inside = ThreadLocal.withInitial(() -> false);
    private ControlPoints() { }

    /** The owner identifies the registration; a continuous module passes its provider so the host can report a failure. */
    public static void register(String point, Object owner, Handler handler) {
        if (point == null || point.length() > 64 || !ID.matcher(point).matches()) throw new IllegalArgumentException("Invalid control point");
        var next = new Registration(point, Objects.requireNonNull(owner), Objects.requireNonNull(handler));
        if (points.putIfAbsent(point, next) != null) throw new IllegalStateException("Control point already owned: " + point);
    }
    /** Any thread, never blocks: no new call reaches the handler. Await the result for calls still in flight. */
    public static Lease unregister(String point, Object owner) {
        Registration r = points.get(point);
        if (r == null || r.owner != owner || !points.remove(point, r)) return Lease.closedLease();
        r.calls.close();
        return r.calls;
    }
    /** Why the owner's handler at this point failed, or null. */
    public static Throwable failure(String point, Object owner) {
        Registration r = points.get(point);
        return r != null && r.owner == owner ? r.failure : null;
    }
    /** A point registered by this owner whose handler failed, or null. */
    public static String failed(Object owner) {
        for (Registration r : points.values()) if (r.owner == owner && r.failure != null) return r.point;
        return null;
    }
    public static int call(String point, Object target, int mode, float argument) {
        Registration r = points.get(point);
        if (r == null || inside.get() || !r.calls.acquire()) return 0;
        inside.set(true);
        try { return r.handler.call(target, mode, argument); }
        catch (Throwable failure) { r.fail(failure); return 0; }
        finally { inside.set(false); r.calls.release(); }
    }
    public static void observe(String point, Object target, float first, float second, float third) {
        Registration r = points.get(point);
        if (r == null || inside.get() || !r.calls.acquire()) return;
        inside.set(true);
        try { r.handler.observe(target, first, second, third); }
        catch (Throwable failure) { r.fail(failure); }
        finally { inside.set(false); r.calls.release(); }
    }
}
