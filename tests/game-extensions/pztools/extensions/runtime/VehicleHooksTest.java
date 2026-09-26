package pztools.extensions.runtime;

import pztools.extensions.api.VehicleHooks;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Bootstrap hook lease and observational isolation tests; no instrumentation or game classes. */
public final class VehicleHooksTest {
    public static void main(String[] args) throws Exception { run(); }
    public static void run() throws Exception {
        Object owner = new Object(), controller = new Object();
        var calls = new AtomicInteger();
        VehicleHooks.register(owner, new VehicleHooks.Controller() {
            public int tryControl(Object object, int mode, float speed) { return VehicleHooks.APPLIED; }
            public void observeNative(Object object, float engine, float brake, float steering) {
                check(object == controller && engine == 10 && brake == 20 && steering == 0.25f, "Native arguments changed");
                calls.incrementAndGet();
                VehicleHooks.observeNative(object, engine, brake, steering);
                check(VehicleHooks.tryControl(object, 1, 0) == VehicleHooks.VANILLA, "Observation reentered a calculation");
            }
        });
        VehicleHooks.observeNative(controller, 10, 20, 0.25f);
        check(calls.get() == 1 && VehicleHooks.failure(owner) == null, "Reentrant observation was not suppressed");
        VehicleHooks.unregister(owner).await(1000);
        VehicleHooks.observeNative(controller, 10, 20, 0.25f);
        check(calls.get() == 1, "Retired observer still received data");

        var entered = new CountDownLatch(1); var release = new CountDownLatch(1);
        VehicleHooks.register(owner, new VehicleHooks.Controller() {
            public int tryControl(Object object, int mode, float speed) { return VehicleHooks.APPLIED; }
            public void observeNative(Object object, float engine, float brake, float steering) {
                entered.countDown();
                try { check(release.await(2, TimeUnit.SECONDS), "Observation release timeout"); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new AssertionError(interrupted); }
            }
        });
        var observer = new Thread(() -> VehicleHooks.observeNative(controller, 1, 2, 3)); observer.start();
        check(entered.await(2, TimeUnit.SECONDS), "Observer did not enter");
        var retired = VehicleHooks.unregister(owner);
        try { retired.await(5); throw new AssertionError("Retirement ignored active observation"); }
        catch (TimeoutException expected) { }
        release.countDown(); observer.join(2000); retired.await(1000);
        check(!observer.isAlive(), "Observation did not drain");

        VehicleHooks.register(owner, new VehicleHooks.Controller() {
            public int tryControl(Object object, int mode, float speed) { return VehicleHooks.APPLIED | VehicleHooks.OWN_OFFROAD; }
            public void observeNative(Object object, float engine, float brake, float steering) { throw new AssertionError("fixture-observer"); }
        });
        int committedOutcome = VehicleHooks.tryControl(controller, 1, 0);
        VehicleHooks.observeNative(controller, 1, 2, 3);
        check(committedOutcome == (VehicleHooks.APPLIED | VehicleHooks.OWN_OFFROAD) && VehicleHooks.failure(owner) != null,
            "Observation fault changed already selected control result or escaped latch");
        VehicleHooks.unregister(owner).await(1000);
        var steeringEntered=new CountDownLatch(1); var steeringRelease=new CountDownLatch(1);
        VehicleHooks.register(owner,(object,mode,speed)-> {
            check(mode==VehicleHooks.STEERING,"Steering phase uses existing typed dispatcher");
            check(VehicleHooks.tryControl(object,VehicleHooks.STEERING,speed)==VehicleHooks.VANILLA,"Steering cannot recursively reenter");
            steeringEntered.countDown(); check(steeringRelease.await(2,TimeUnit.SECONDS),"Steering release timeout");
            return VehicleHooks.APPLIED;
        });
        var steeringResult=new AtomicInteger();
        var steeringThread=new Thread(()->steeringResult.set(VehicleHooks.tryControl(controller,VehicleHooks.STEERING,0)));
        steeringThread.start(); check(steeringEntered.await(2,TimeUnit.SECONDS),"Steering lease did not enter");
        var steeringRetired=VehicleHooks.unregister(owner);
        check(VehicleHooks.tryControl(controller,VehicleHooks.STEERING,0)==VehicleHooks.VANILLA,"Retired steering admits no new callback");
        try { steeringRetired.await(5); throw new AssertionError("Retirement ignored active steering"); }
        catch(TimeoutException expected) { }
        steeringRelease.countDown(); steeringThread.join(2000); steeringRetired.await(1000);
        check(!steeringThread.isAlive() && steeringResult.get()==VehicleHooks.APPLIED,"Accepted steering transaction did not drain");
        System.out.println("PASS: native observation identity, recursion, retirement drain and fault isolation");
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
