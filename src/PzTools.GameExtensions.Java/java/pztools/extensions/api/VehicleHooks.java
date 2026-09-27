package pztools.extensions.api;

import java.util.Objects;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;

/** One bounded invocation owns its generation; only primitive decisions outlive the call. */
public final class VehicleHooks {
    public static final int VANILLA = 0, APPLIED = 1, DIRECTION_HOLD = 2, OWN_OFFROAD = 4;
    public static final int FORWARD = 1, REVERSE = 2, BRAKING = 3, NO_CONTROL = 4;
    /** A separate, pre-steering-block transaction using the existing bootstrap10 dispatcher ABI. */
    public static final int STEERING = 5;
    @FunctionalInterface public interface Controller {
        /** Exceptions and VANILLA are permitted only before committing any game field. */
        int tryControl(Object controller, int mode, float speed) throws Exception;
        /** Observation only: final arguments immediately before the native call; never write game fields. */
        default void observeNative(Object controller, float engine, float brake, float steering) { }
    }
    private static final AtomicReference<Registration> current = new AtomicReference<>();
    private static final ThreadLocal<Boolean> entered = ThreadLocal.withInitial(() -> false);
    private VehicleHooks() { }
    private static final class Registration {
        final Object owner; final Controller callback;
        boolean retired; int active; volatile Throwable failure;
        Registration(Object owner, Controller callback) { this.owner = owner; this.callback = callback; }
        synchronized boolean acquire() { if (retired || failure != null) return false; active++; return true; }
        synchronized void release() { active--; notifyAll(); }
        synchronized void retire() { retired = true; }
        synchronized void await(long millis) throws InterruptedException, TimeoutException {
            long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(millis);
            while (active != 0) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) throw new TimeoutException("Vehicle callback still in flight");
                TimeUnit.NANOSECONDS.timedWait(this, remaining);
            }
        }
    }
    public static final class Retirement {
        private final Registration registration;
        private Retirement(Registration registration) { this.registration = registration; }
        public void await(long timeoutMillis) throws InterruptedException, TimeoutException {
            if (registration != null) registration.await(timeoutMillis);
        }
    }
    public static void register(Object owner, Controller controller) {
        var next = new Registration(Objects.requireNonNull(owner), Objects.requireNonNull(controller));
        if (!current.compareAndSet(null, next)) throw new IllegalStateException("Vehicle capability already owned");
    }
    public static Retirement unregister(Object owner) {
        Registration r = current.get();
        if (r == null || r.owner != owner || !current.compareAndSet(r, null)) return new Retirement(null);
        r.retire(); return new Retirement(r);
    }
    public static Throwable failure(Object owner) {
        Registration r = current.get(); return r != null && r.owner == owner ? r.failure : null;
    }
    public static Throwable failure() { Registration r = current.get(); return r == null ? null : r.failure; }
    public static int tryControl(Object controller, int mode, float speed) {
        Registration r = current.get();
        if (r == null || entered.get() || !r.acquire()) return VANILLA;
        entered.set(true);
        try {
            int result = r.callback.tryControl(controller, mode, speed);
            if (result != VANILLA && result != APPLIED && result != DIRECTION_HOLD && result != (APPLIED | OWN_OFFROAD)) {
                // Providers must validate their outcome BEFORE committing fields.
                r.failure = new IllegalStateException("Invalid vehicle outcome"); return VANILLA;
            }
            return result;
        } catch (Throwable failure) {
            r.failure = failure; return VANILLA;
        } finally { entered.set(false); r.release(); }
    }
    /** Observational failure never changes this step's result or repeats native/vanilla control. */
    public static void observeNative(Object controller, float engine, float brake, float steering) {
        Registration r = current.get();
        if (r == null || entered.get() || !r.acquire()) return;
        entered.set(true);
        try { r.callback.observeNative(controller, engine, brake, steering); }
        catch (Throwable failure) { r.failure = failure; }
        finally { entered.set(false); r.release(); }
    }
}
