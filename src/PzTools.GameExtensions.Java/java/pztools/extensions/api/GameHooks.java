package pztools.extensions.api;

import java.util.*;
import java.util.concurrent.*;

/** Nonthrowing read-only observation with generation-paired exits and drainable retirement. */
public final class GameHooks {
    public interface Observer {
        default void enter() { }
        default void exit(Throwable failure) { }
        default void error(Throwable failure) { }
    }
    private static final class Registration {
        final Observer observer; volatile Throwable failure;
        private boolean retired; private int active;
        Registration(Observer observer) { this.observer = observer; }
        synchronized boolean acquire() { if (retired) return false; active++; return true; }
        synchronized void release() { active--; notifyAll(); }
        synchronized void retire() { retired = true; }
        synchronized void await(long deadline) throws InterruptedException, TimeoutException {
            while (active != 0) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) throw new TimeoutException("Observation still in flight");
                TimeUnit.NANOSECONDS.timedWait(this, remaining);
            }
        }
        void failed(Throwable problem) { if (failure == null) failure = problem; }
    }
    public static final class Retirement {
        private final Registration registration;
        private Retirement(Registration registration) { this.registration = registration; }
        public void await(long timeoutMillis) throws InterruptedException, TimeoutException {
            if (registration != null) registration.await(System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis));
        }
    }
    private static final Registration NONE = new Registration(null);
    private static final ConcurrentHashMap<String, Registration> observers = new ConcurrentHashMap<>();
    // Reused bootstrap-owned containers; empty stacks retain no provider/loader references.
    private static final ThreadLocal<Map<String, ArrayDeque<Registration>>> scopes = ThreadLocal.withInitial(HashMap::new);
    private GameHooks() { }
    public static void register(String point, Observer observer) {
        if (observers.putIfAbsent(point, new Registration(Objects.requireNonNull(observer))) != null)
            throw new IllegalStateException("Observation point already owned: " + point);
    }
    public static Retirement unregister(String point, Observer observer) {
        Registration r = observers.get(point);
        if (r == null || r.observer != observer || !observers.remove(point, r)) return new Retirement(null);
        r.retire(); return new Retirement(r);
    }
    public static Throwable failure(String point) { Registration r = observers.get(point); return r == null ? null : r.failure; }
    public static void enter(String point) {
        Registration r = observers.get(point);
        if (r == null || !r.acquire()) r = NONE;
        var current = scopes.get();
        if (r == NONE && !current.containsKey(point)) return;
        current.computeIfAbsent(point, ignored -> new ArrayDeque<>()).push(r);
        if (r != NONE) try { r.observer.enter(); } catch (Throwable failure) { r.failed(failure); }
    }
    public static void exit(String point, Throwable error) {
        var stack = scopes.get().get(point);
        if (stack == null || stack.isEmpty()) return; // A frame entered before instrumentation was installed.
        Registration r = stack.pop();
        // Stable point names reuse empty bootstrap-owned stacks; popped registrations retain no module.
        if (r == NONE) return;
        try { r.observer.exit(error); } catch (Throwable failure) { r.failed(failure); }
        finally { r.release(); }
    }
    public static void error(String point, Throwable error) {
        Registration r = observers.get(point);
        if (r == null || !r.acquire()) return;
        try { r.observer.error(error); } catch (Throwable failure) { r.failed(failure); }
        finally { r.release(); }
    }
}
