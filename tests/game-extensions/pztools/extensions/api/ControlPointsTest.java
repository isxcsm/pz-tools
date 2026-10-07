package pztools.extensions.api;

import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** The resident control-point registry and its lease: ownership, re-entry, drain and fault latch. No game classes. */
public final class ControlPointsTest {
    public static void main(String[] args) throws Exception { run(); }
    public static void run() throws Exception {
        ownership();
        reentry();
        drain();
        faults();
        lease();
        System.out.println("PASS: control point ownership, re-entry, retirement drain, fault latch and lease");
    }
    private static void ownership() throws Exception {
        Object owner = new Object(), other = new Object();
        check(ControlPoints.call("test.free", null, 1, 0) == 0, "A point nobody registered runs the game's code");
        ControlPoints.register("test.owned", owner, (target, mode, argument) -> mode * 10 + (int)argument);
        check(ControlPoints.call("test.owned", null, 4, 2) == 42, "Mode and argument reach the handler");
        refused(() -> ControlPoints.register("test.owned", other, (target, mode, argument) -> 1), IllegalStateException.class, "A second owner");
        refused(() -> ControlPoints.register("Test Point", owner, (target, mode, argument) -> 1), IllegalArgumentException.class, "An invalid name");
        refused(() -> ControlPoints.register("a".repeat(65), owner, (target, mode, argument) -> 1), IllegalArgumentException.class, "An overlong name");
        ControlPoints.unregister("test.owned", other).await(0);
        check(ControlPoints.call("test.owned", null, 4, 2) == 42, "Another owner cannot unregister the point");
        ControlPoints.unregister("test.owned", owner).await(1000);
        check(ControlPoints.call("test.owned", null, 4, 2) == 0, "An unregistered point runs the game's code");
        ControlPoints.register("test.owned", other, (target, mode, argument) -> 7);
        check(ControlPoints.call("test.owned", null, 0, 0) == 7, "A retired point can be owned again");
        ControlPoints.unregister("test.owned", other).await(1000);
    }
    private static void reentry() throws Exception {
        Object owner = new Object(), target = new Object();
        var observed = new AtomicInteger();
        ControlPoints.register("test.inner", owner, (t, mode, argument) -> 9);
        ControlPoints.register("test.outer", owner, new ControlPoints.Handler() {
            public int call(Object t, int mode, float argument) {
                check(ControlPoints.call("test.outer", t, mode, argument) == 0, "A handler re-entered its own point");
                check(ControlPoints.call("test.inner", t, mode, argument) == 0, "A handler entered another point");
                return 3;
            }
            public void observe(Object t, float first, float second, float third) {
                check(t == target && first == 10 && second == 20 && third == 0.25f, "Observed arguments changed");
                observed.incrementAndGet();
                ControlPoints.observe("test.outer", t, first, second, third);
                check(ControlPoints.call("test.outer", t, 1, 0) == 0, "Observation re-entered a call");
            }
        });
        check(ControlPoints.call("test.outer", target, 1, 0) == 3, "Outer call lost its outcome");
        ControlPoints.observe("test.outer", target, 10, 20, 0.25f);
        check(observed.get() == 1 && ControlPoints.failed(owner) == null, "Re-entrant observation was not suppressed");
        check(ControlPoints.call("test.inner", target, 1, 0) == 9, "The guard outlived the outer call");
        ControlPoints.unregister("test.outer", owner).await(1000);
        ControlPoints.unregister("test.inner", owner).await(1000);
        ControlPoints.observe("test.outer", target, 10, 20, 0.25f);
        check(observed.get() == 1, "A retired observer still received data");
    }
    private static void drain() throws Exception {
        Object owner = new Object();
        var entered = new CountDownLatch(1); var release = new CountDownLatch(1);
        ControlPoints.register("test.drain", owner, new ControlPoints.Handler() {
            public int call(Object target, int mode, float argument) throws Exception {
                entered.countDown(); check(release.await(2, TimeUnit.SECONDS), "Call release timeout"); return 1;
            }
            public void observe(Object target, float first, float second, float third) throws Exception {
                entered.countDown(); check(release.await(2, TimeUnit.SECONDS), "Observation release timeout");
            }
        });
        var result = new AtomicInteger();
        var caller = new Thread(() -> result.set(ControlPoints.call("test.drain", null, 1, 0))); caller.start();
        check(entered.await(2, TimeUnit.SECONDS), "Call did not enter");
        var retired = ControlPoints.unregister("test.drain", owner);
        check(ControlPoints.call("test.drain", null, 1, 0) == 0, "A retired point admitted a new call");
        try { retired.await(5); throw new AssertionError("Retirement ignored a call in flight"); }
        catch (TimeoutException expected) { }
        release.countDown(); caller.join(2000); retired.await(1000);
        check(!caller.isAlive() && result.get() == 1, "An admitted call did not finish with its outcome");

        var observing = new CountDownLatch(1); var observed = new CountDownLatch(1);
        ControlPoints.register("test.drain", owner, new ControlPoints.Handler() {
            public int call(Object target, int mode, float argument) { return 1; }
            public void observe(Object target, float first, float second, float third) throws Exception {
                observing.countDown(); check(observed.await(2, TimeUnit.SECONDS), "Observation release timeout");
            }
        });
        var observer = new Thread(() -> ControlPoints.observe("test.drain", null, 1, 2, 3)); observer.start();
        check(observing.await(2, TimeUnit.SECONDS), "Observer did not enter");
        var observerRetired = ControlPoints.unregister("test.drain", owner);
        try { observerRetired.await(5); throw new AssertionError("Retirement ignored an observation in flight"); }
        catch (TimeoutException expected) { }
        observed.countDown(); observer.join(2000); observerRetired.await(1000);
        check(!observer.isAlive(), "Observation did not drain");
    }
    private static void faults() throws Exception {
        Object owner = new Object(), bystander = new Object();
        var calls = new AtomicInteger(); var failing = new AtomicBoolean(true);
        ControlPoints.register("test.healthy", bystander, (target, mode, argument) -> 1);
        ControlPoints.register("test.fault", owner, (target, mode, argument) -> {
            calls.incrementAndGet();
            if (failing.get()) throw new IllegalStateException("fixture-before-commit");
            return 1;
        });
        check(ControlPoints.call("test.fault", null, 1, 0) == 0, "A failed call did not fall back");
        failing.set(false);
        check(ControlPoints.call("test.fault", null, 1, 0) == 0 && calls.get() == 1, "A failed handler was called again");
        check("test.fault".equals(ControlPoints.failed(owner)) && ControlPoints.failure("test.fault", owner) instanceof IllegalStateException,
            "The failed point was not reported for its owner");
        check(ControlPoints.failure("test.fault", bystander) == null && ControlPoints.failed(bystander) == null
            && ControlPoints.call("test.healthy", null, 1, 0) == 1, "One point's fault reached another owner");
        ControlPoints.unregister("test.fault", owner).await(1000);
        check(ControlPoints.failed(owner) == null, "A retired point still reports its fault");
        ControlPoints.unregister("test.healthy", bystander).await(1000);

        ControlPoints.register("test.observe", owner, new ControlPoints.Handler() {
            public int call(Object target, int mode, float argument) { return 5; }
            public void observe(Object target, float first, float second, float third) { throw new AssertionError("fixture-observer"); }
        });
        int taken = ControlPoints.call("test.observe", null, 1, 0);
        ControlPoints.observe("test.observe", null, 1, 2, 3);
        check(taken == 5 && "test.observe".equals(ControlPoints.failed(owner)), "An observation fault changed the outcome or escaped the latch");
        check(ControlPoints.call("test.observe", null, 1, 0) == 0, "A point latched by observation still took decisions");
        ControlPoints.unregister("test.observe", owner).await(1000);
    }
    private static void lease() throws Exception {
        var lease = new Lease();
        check(lease.acquire() && lease.acquire(), "An open lease refused a call");
        lease.close();
        check(!lease.acquire(), "A closed lease admitted a call");
        lease.release();
        try { lease.await(5); throw new AssertionError("Await ignored a call in flight"); }
        catch (TimeoutException expected) { }
        lease.release(); lease.release(); // A stray release cannot go below zero.
        lease.await(0);
        check(!lease.acquire(), "A drained lease reopened");
        var nothing = Lease.closedLease();
        check(!nothing.acquire(), "The empty retirement admitted a call");
        nothing.await(0);
    }
    @FunctionalInterface private interface Action { void run() throws Exception; }
    private static void refused(Action action, Class<? extends Exception> expected, String what) throws Exception {
        try { action.run(); }
        catch (Exception failure) { if (expected.isInstance(failure)) return; throw failure; }
        throw new AssertionError(what + " was accepted");
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
