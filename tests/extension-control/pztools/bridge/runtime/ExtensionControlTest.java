package pztools.bridge.runtime;

import pztools.extensions.api.*;
import pztools.bridge.AgentEntry;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.*;

/** Protocol parsing/lease tests with synthetic GameWindow classes, without attaching to any JVM. */
public final class ExtensionControlTest {
    public static void main(String[] args) throws Exception {
        String config = Base64.getEncoder().encodeToString("force_scale\t1.25\nprobe_only\ttrue\n".getBytes(StandardCharsets.UTF_8));
        check(ExtensionControl.parseConfig(config).equals(Map.of("force_scale", "1.25", "probe_only", "true")), "Typed map transport changed");
        for (String invalid : List.of("a\t1\na\t2\n", "bad key\t1", "key\tx\ty", "key\tx\r")) {
            try { ExtensionControl.parseConfig(Base64.getEncoder().encodeToString(invalid.getBytes(StandardCharsets.UTF_8))); throw new AssertionError("Invalid configuration accepted"); }
            catch (java.io.IOException expected) { }
        }
        String process = RuntimeIdentity.processId(), world = "a".repeat(32), generation = "b".repeat(32);
        var status = new ContinuousModules.Status("Active", "test reason", process, world, generation, 4, "0.1.0", "c".repeat(64), "latest=1");
        String[] fields = ExtensionControl.wire("command", status).split("\t", -1);
        check(fields.length == 11 && fields[4].equals(process) && fields[7].equals("4")
            && new String(Base64.getDecoder().decode(fields[10]), StandardCharsets.UTF_8).equals("latest=1"), "STATE1 field contract changed");
        var clock = new AtomicLong(100);
        var session = new ExtensionControl.Session(null, Class.forName("zombie.GameWindow"), clock::get, FixtureModules::new);
        String epoch = "d".repeat(32);
        check(session.command("STATUS\ts1\t" + epoch).split("\t", -1)[2].equals("Disabled"), "Fresh connection unexpectedly owns a module");
        String off = "OFF\to1\t" + epoch;
        String response = session.command(off);
        check(session.command(off).equals(response), "Identical command was not idempotent");
        try { session.command("PING\to1\t" + epoch); throw new AssertionError("Command ID reuse accepted"); }
        catch (java.io.IOException expected) { }
        try { session.command("PING\tp2\t" + "e".repeat(32)); throw new AssertionError("Controller epoch replacement accepted"); }
        catch (java.io.IOException expected) { }
        clock.addAndGet(TimeUnit.SECONDS.toNanos(4)); session.command("PING\tp3\t" + epoch);
        clock.addAndGet(TimeUnit.SECONDS.toNanos(4)); check(!session.expired(), "Heartbeat did not renew lease");
        clock.addAndGet(TimeUnit.SECONDS.toNanos(1)); check(session.expired(), "Lease never expired");
        try { session.command("PING\tp4\t" + epoch); throw new AssertionError("Expired owner resurrected itself"); }
        catch (java.io.IOException expected) { }
        session.close();
        residentFailureSurvivesReconnect();
        pausedPendingOff();
        lifecycleRelease();
        worldIdentity();
        ExtensionControlConcurrencyTest.run();
        System.out.println("PASS: extension wire map bounds, STATE fields, command replay, controller epochs and bounded lease");
    }
    private static void residentFailureSurvivesReconnect() throws Exception {
        var modules = new FixtureModules();
        modules.restartRequired = true;
        var loads = new AtomicInteger();
        String epoch = "f".repeat(32);
        for (int connection = 0; connection < 2; connection++) {
            var session = new ExtensionControl.Session(null, zombie.GameWindow.class, System::nanoTime,
                () -> { loads.incrementAndGet(); return modules; });
            try {
                check(session.command("STATUS\ts1\t" + epoch).split("\t", -1)[2].equals("RestartRequired"),
                    "Reconnection hid the resident host's restart requirement");
                check(session.command("OFF\to1\t" + epoch).split("\t", -1)[2].equals("RestartRequired"),
                    "OFF pretended the resident host had recovered");
                session.command("PING\tp1\t" + epoch);
                check(loads.get() == connection + 1, "Heartbeat unnecessarily reloaded the resident host");
                check(modules.applies.get() == 0, "Status inspection attempted to enable the module");
            } finally { session.close(); }
        }
    }
    private static void worldIdentity() throws Exception {
        zombie.GameWindow.mode="normal"; zombie.GameWindow.gameThread=Thread.currentThread();
        zombie.ZomboidFileSystem.path="synthetic-world";
        zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1);
        var session = new ExtensionControl.Session(null, zombie.GameWindow.class);
        var field = ExtensionControl.Session.class.getDeclaredField("modules"); field.setAccessible(true);
        var modules = new FixtureModules(); field.set(session, modules);
        try {
            session.poll();
            var first = modules.context;
            check(first != null && first.worldIdentity() == zombie.iso.IsoWorld.instance.currentCell
                && first.worldIdentity() != zombie.iso.IsoWorld.instance
                && first.worldId().equals(RuntimeIdentity.worldId(zombie.iso.IsoWorld.instance.currentCell)),
                "Continuous context does not use WATCH's currentCell identity");
            zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(0);
            zombie.iso.IsoWorld.instance.currentCell = new Object();
            session.poll();
            check(!first.worldValid().get() && modules.revokes.get() == 1 && modules.ticks.get() == 1,
                "Paused cell replacement failed to invalidate old context immediately");
            zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1); session.poll();
            check(modules.context.worldIdentity() == zombie.iso.IsoWorld.instance.currentCell
                && !modules.context.worldId().equals(first.worldId()), "Reloaded cell reused the prior world identity");
        } finally { session.close(); zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1); }
    }
    private static void pausedPendingOff() throws Exception {
        zombie.GameWindow.mode="normal"; zombie.GameWindow.gameThread=Thread.currentThread();
        zombie.ZomboidFileSystem.path="synthetic-world";
        zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(0);
        var modules=new FixtureModules(); modules.pending=true;
        var session=new ExtensionControl.Session(null,zombie.GameWindow.class,System::nanoTime,()->modules);
        String epoch="e".repeat(32);
        try {
            check(session.command("STATUS\tpaused-status\t"+epoch).split("\t",-1)[2].equals("Pending"),
                "Fixture did not begin with a pending request");
            session.poll();
            check(modules.ticks.get()==0 && modules.pending,"Paused poll entered the physical safe-boundary callback");
            check(session.command("OFF\tpaused-off\t"+epoch).split("\t",-1)[2].equals("Disabled")
                && modules.closes.get()==1 && !modules.pending,"Paused OFF waited for another game tick");
            zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1); session.poll();
            check(modules.appliedPending.get()==0,"Resume applied a pending request that OFF had cancelled");
        } finally { session.close(); zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1); }
    }
    private static void lifecycleRelease() throws Exception {
        var pause = AgentEntry.class.getDeclaredField("dispatchPaused"); pause.setAccessible(true);
        var modulesField = ExtensionControl.Session.class.getDeclaredField("modules"); modulesField.setAccessible(true);
        var clock = new AtomicLong(100);
        var session = new ExtensionControl.Session(null, Class.forName("zombie.GameWindow"), clock::get);
        var modules = new FixtureModules(); modulesField.set(session, modules);
        check(AgentEntry.acquireLifecycle(session, session::poll), "Lifecycle slot occupied before test");
        Object saveOwner = new Object(); var saves = new AtomicInteger(); var watches = new AtomicInteger();
        check(AgentEntry.acquire(saveOwner, saves::incrementAndGet), "Save slot occupied before test");
        AgentEntry.observe(watches::incrementAndGet);
        try {
            pause.setBoolean(null, true);
            var closing = new Thread(session::close); closing.start(); closing.join(2000);
            check(!closing.isAlive() && modules.revokes.get() == 1 && modules.closes.get() == 1,
                "dispatchPaused close waited for a game tick");
            session.poll();
            check(modules.ticks.get() == 0, "Late captured lifecycle callback touched a closed generation");
            Object nextOwner = new Object(); var nextTicks = new AtomicInteger();
            check(AgentEntry.acquireLifecycle(nextOwner, nextTicks::incrementAndGet), "Closed session leaked lifecycle ownership");
            pause.setBoolean(null, false); AgentEntry.poll(); AgentEntry.releaseLifecycle(nextOwner);
            check(saves.get() == 1 && watches.get() == 1 && nextTicks.get() == 1,
                "Lifecycle close displaced save or WATCH callbacks");

            var failing = new ExtensionControl.Session(null, Class.forName("zombie.GameWindow"), clock::get);
            var failingModules = new FixtureModules(); failingModules.throwRevoke = true; modulesField.set(failing, failingModules);
            check(AgentEntry.acquireLifecycle(failing, failing::poll), "Cannot acquire faulting lifecycle");
            failing.close();
            check(failingModules.closes.get() == 1 && AgentEntry.acquireLifecycle(nextOwner, nextTicks::incrementAndGet),
                "Failed revoke skipped retirement or leaked bootstrap ownership");
            AgentEntry.releaseLifecycle(nextOwner);

            var leased = new ExtensionControl.Session(null, Class.forName("zombie.GameWindow"), clock::get);
            var leasedModules = new FixtureModules(); modulesField.set(leased, leasedModules);
            clock.addAndGet(TimeUnit.SECONDS.toNanos(5)); leased.poll();
            check(leasedModules.revokes.get() == 1 && leasedModules.ticks.get() == 0, "Expired lease reached game state");
            leased.close();

            // Dispatch may have captured a callback before EOF. Closing it must make that callback inert.
            var late = new ExtensionControl.Session(null, Class.forName("zombie.GameWindow"), clock::get);
            var lateModules = new FixtureModules(); modulesField.set(late, lateModules);
            var observerEntered = new CountDownLatch(1); var releaseObserver = new CountDownLatch(1);
            AgentEntry.observe(() -> { observerEntered.countDown(); try { releaseObserver.await(2, TimeUnit.SECONDS); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); } });
            check(AgentEntry.acquireLifecycle(late, late::poll), "Cannot acquire late lifecycle");
            var dispatch = new Thread(AgentEntry::poll); dispatch.start();
            check(observerEntered.await(2, TimeUnit.SECONDS), "Dispatch did not enter observer");
            late.close(); releaseObserver.countDown(); dispatch.join(2000);
            check(!dispatch.isAlive() && lateModules.ticks.get() == 0, "Captured callback resurrected an EOF-closed owner");
        } finally { pause.setBoolean(null, false); AgentEntry.observe(null); AgentEntry.release(saveOwner); session.close(); }
    }
    private static final class FixtureModules implements ContinuousModules {
        final AtomicInteger ticks = new AtomicInteger(), revokes = new AtomicInteger(), closes = new AtomicInteger(), applies = new AtomicInteger(), appliedPending = new AtomicInteger();
        boolean throwRevoke, restartRequired, pending;
        ContinuousProvider.Context context;
        public Status apply(Apply request, java.lang.instrument.Instrumentation i, ClassLoader l, String version) { applies.incrementAndGet(); return status(); }
        public void tick(ContinuousProvider.Context context) { this.context=context; ticks.incrementAndGet(); if(pending){pending=false;appliedPending.incrementAndGet();} }
        public void revoke(String reason) { revokes.incrementAndGet(); if (throwRevoke) throw new AssertionError("fixture revoke"); }
        public Status deactivate(String reason) { closes.incrementAndGet(); pending=false; return status(); }
        public Status status() { return new Status(restartRequired ? "RestartRequired" : pending ? "Pending" : "Disabled", null,
            RuntimeIdentity.processId(), null, null, -1, null, null, ""); }
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
