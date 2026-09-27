package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;
import pztools.extensions.api.ContinuousModules;
import pztools.extensions.api.ContinuousProvider;
import pztools.extensions.api.RuntimeIdentity;
import java.lang.instrument.Instrumentation;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.LongSupplier;

/** Latch-controlled owner retirement tests against the production Session, without a game JVM. */
public final class ExtensionControlConcurrencyTest {
    private static final String EPOCH = "a".repeat(32);
    private static final String WORLD = "b".repeat(32);
    private static final long TIMEOUT_SECONDS = 5;

    private ExtensionControlConcurrencyTest() { }

    public static void run() throws Exception {
        Thread previousThread = zombie.GameWindow.gameThread;
        String previousMode = zombie.GameWindow.mode;
        String previousPath = zombie.ZomboidFileSystem.path;
        Object previousState = zombie.GameWindow.states.current;
        Object previousCell = zombie.iso.IsoWorld.instance.currentCell;
        int previousSpeed = zombie.ui.UIManager.getSpeedControls().getCurrentGameSpeed();
        boolean previousClient = zombie.network.GameClient.client;
        boolean previousClientSave = zombie.network.GameClient.clientSave;
        boolean previousServer = zombie.network.GameServer.server;
        boolean previousExiting = zombie.core.Core.exiting;
        try {
            zombie.GameWindow.mode = "normal";
            zombie.GameWindow.gameThread = Thread.currentThread();
            zombie.GameWindow.states.current = new zombie.gameStates.IngameState();
            zombie.iso.IsoWorld.instance.currentCell = new Object();
            zombie.ZomboidFileSystem.path = "synthetic-world";
            zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1);
            zombie.network.GameClient.client = false;
            zombie.network.GameClient.clientSave = false;
            zombie.network.GameServer.server = false;
            zombie.core.Core.exiting = false;
            closeRetainsOwnershipUntilCleanup();
            admittedPollDrainsBeforeReconnect();
            admittedApplyDrainsBeforeReconnect();
            pollDoesNotWaitForCommandCleanup();
            cleanupFailuresReleaseOwnership();
        } finally {
            zombie.GameWindow.gameThread = previousThread;
            zombie.GameWindow.mode = previousMode;
            zombie.GameWindow.states.current = previousState;
            zombie.iso.IsoWorld.instance.currentCell = previousCell;
            zombie.ZomboidFileSystem.path = previousPath;
            zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(previousSpeed);
            zombie.network.GameClient.client = previousClient;
            zombie.network.GameClient.clientSave = previousClientSave;
            zombie.network.GameServer.server = previousServer;
            zombie.core.Core.exiting = previousExiting;
        }
        System.out.println("PASS: extension owner retirement, pre-host poll/APPLY drain, nonblocking poll and failure cleanup");
    }

    private static void closeRetainsOwnershipUntilCleanup() throws Exception {
        try (var scope = new Scope()) {
            var modules = new FixtureModules();
            var old = scope.session(modules, () -> 100L);
            var next = scope.session(modules, () -> 100L);
            acquire(old);
            apply(old, "old-active");
            modules.deactivateGate = scope.gate();
            var close = scope.start("close-cleanup", old::close);
            modules.deactivateGate.awaitEntered();
            check(old.expired() && modules.revokes.get() == 1, "Close did not immediately revoke the old owner");
            check(!AgentEntry.acquireLifecycle(next, next::poll), "Cleanup released lifecycle ownership before deactivate returned");

            scope.start("duplicate-close", old::close).returnsPromptly();
            scope.start("late-poll-during-close", old::poll).returnsPromptly();
            check(modules.deactivations.get() == 1 && modules.revokes.get() == 1 && modules.ticks.get() == 0,
                "Duplicate close or a late poll reentered host cleanup");
            close.remainsBlocked();
            modules.deactivateGate.open();
            close.finish();
            acquire(next);
            apply(next, "next-active");
            assertOldOwnerInert(old, next, modules);
        }
    }

    private static void admittedPollDrainsBeforeReconnect() throws Exception {
        try (var scope = new Scope()) {
            var modules = new FixtureModules();
            var clock = new PollClock(scope.gate());
            var old = scope.session(modules, clock);
            var next = scope.session(modules, () -> 100L);
            acquire(old);
            old.command("STATUS\tpoll-initial\t" + EPOCH);
            var poll = scope.start("admitted-poll", () -> {
                zombie.GameWindow.gameThread = Thread.currentThread();
                clock.pollingThread = Thread.currentThread();
                old.poll();
            });
            // expired() has read active=true and is paused at the clock, before any host tick.
            clock.gate.awaitEntered();
            var close = scope.start("close-admitted-poll", old::close);
            await(modules.revokeEntered, "Close did not revoke while poll was admitted");
            close.remainsBlocked();
            check(modules.deactivations.get() == 0 && modules.ticks.get() == 0,
                "Close retired the host before the admitted pre-host poll drained");
            check(!AgentEntry.acquireLifecycle(next, next::poll), "An admitted pre-host poll lost lifecycle ownership");

            clock.gate.open();
            poll.finish();
            close.finish();
            check(modules.ticks.get() == 1 && modules.context != null,
                "The fixture did not exercise the late context publication boundary");
            check(!modules.context.worldValid().get() && !modules.enabled.get() && modules.deactivations.get() == 1,
                "Close failed to invalidate a context published by an already admitted poll");
            acquire(next);
            apply(next, "next-after-poll");
            assertOldOwnerInert(old, next, modules);
        }
    }

    private static void admittedApplyDrainsBeforeReconnect() throws Exception {
        try (var scope = new Scope()) {
            var modules = new FixtureModules();
            var old = scope.session(modules, () -> 100L);
            var next = scope.session(modules, () -> 100L);
            acquire(old);
            old.command("STATUS\tapply-initial\t" + EPOCH);
            modules.applyGate = scope.gate();
            var applying = scope.start("admitted-apply", () -> apply(old, "in-flight-apply"));
            modules.applyGate.awaitEntered();
            var close = scope.start("close-admitted-apply", old::close);
            await(modules.revokeEntered, "Close did not revoke while APPLY was admitted");
            close.remainsBlocked();
            check(modules.deactivations.get() == 0, "Close retired the host before APPLY drained");
            check(!AgentEntry.acquireLifecycle(next, next::poll), "An in-flight APPLY lost lifecycle ownership");

            modules.applyGate.open();
            applying.finish();
            close.finish();
            check(!modules.enabled.get() && modules.deactivations.get() == 1,
                "An in-flight APPLY resurrected the host after close cleanup");
            acquire(next);
            apply(next, "next-after-apply");
            assertOldOwnerInert(old, next, modules);
        }
    }

    private static void pollDoesNotWaitForCommandCleanup() throws Exception {
        try (var scope = new Scope()) {
            var modules = new FixtureModules();
            var session = scope.session(modules, () -> 100L);
            acquire(session);
            apply(session, "before-off");
            modules.deactivateGate = scope.gate();
            var command = scope.start("off-command", () ->
                check(state(session.command("OFF\tblocked-off\t" + EPOCH)).equals("Disabled"), "OFF did not disable the fixture"));
            modules.deactivateGate.awaitEntered();
            scope.start("poll-during-command", () -> {
                zombie.GameWindow.gameThread = Thread.currentThread();
                session.poll();
            }).returnsPromptly();
            check(modules.ticks.get() == 0 && modules.revokes.get() == 0,
                "Poll entered the host while a command was retiring it");
            command.remainsBlocked();
            modules.deactivateGate.open();
            command.finish();
            apply(session, "after-off");
        }
    }

    private static void cleanupFailuresReleaseOwnership() throws Exception {
        for (int failure = 1; failure <= 3; failure++) {
            try (var scope = new Scope()) {
                var modules = new FixtureModules();
                var old = scope.session(modules, () -> 100L);
                var next = scope.session(modules, () -> 100L);
                acquire(old);
                apply(old, "before-failure");
                modules.throwRevoke = (failure & 1) != 0;
                modules.throwDeactivate = (failure & 2) != 0;
                old.close();
                check(modules.revokes.get() == 1 && modules.deactivations.get() == 1,
                    "A cleanup exception skipped the remaining retirement steps");
                acquire(next);
                modules.throwRevoke = false;
                modules.throwDeactivate = false;
                apply(next, "after-failure");
                assertOldOwnerInert(old, next, modules);
            }
        }
    }

    private static void assertOldOwnerInert(ExtensionControl.Session old, ExtensionControl.Session next,
            FixtureModules modules) throws Exception {
        int ticks = modules.ticks.get(), revokes = modules.revokes.get(), deactivations = modules.deactivations.get();
        old.poll();
        old.close();
        check(modules.ticks.get() == ticks && modules.revokes.get() == revokes && modules.deactivations.get() == deactivations,
            "A late old-owner callback touched the reconnected host");
        check(state(next.command("STATUS\tcheck-next-active\t" + EPOCH)).equals("Active"),
            "A late old-owner callback disabled the new generation");
    }

    private static void acquire(ExtensionControl.Session session) {
        check(AgentEntry.acquireLifecycle(session, session::poll), "Lifecycle slot unavailable after retirement");
    }

    private static void apply(ExtensionControl.Session session, String id) throws Exception {
        check(state(session.command("APPLY\t" + id + "\t" + EPOCH + "\t" + RuntimeIdentity.processId()
            + "\t" + WORLD + "\t-1\t1\tpztools.vehicle-drivetrain\tnormal\t")).equals("Active"),
            "Synthetic APPLY did not activate the host");
    }

    private static String state(String response) { return response.split("\t", -1)[2]; }

    private static final class FixtureModules implements ContinuousModules {
        final AtomicInteger ticks = new AtomicInteger(), revokes = new AtomicInteger(), deactivations = new AtomicInteger();
        final AtomicBoolean enabled = new AtomicBoolean();
        final CountDownLatch revokeEntered = new CountDownLatch(1);
        volatile ContinuousProvider.Context context;
        volatile Gate applyGate, deactivateGate;
        volatile boolean throwRevoke, throwDeactivate;

        public Status apply(Apply request, Instrumentation instrumentation, ClassLoader loader, String version) {
            Gate gate = applyGate;
            if (gate != null) gate.pause();
            // Model an already admitted call publishing after close's immediate revoke.
            enabled.set(true);
            return status();
        }
        public void tick(ContinuousProvider.Context current) {
            context = current;
            ticks.incrementAndGet();
            enabled.set(current != null);
        }
        public void revoke(String reason) {
            revokes.incrementAndGet();
            enabled.set(false);
            revokeEntered.countDown();
            if (throwRevoke) throw new AssertionError("Synthetic revoke failure");
        }
        public Status deactivate(String reason) {
            deactivations.incrementAndGet();
            Gate gate = deactivateGate;
            if (gate != null) gate.pause();
            enabled.set(false);
            if (throwDeactivate) throw new AssertionError("Synthetic deactivate failure");
            return status();
        }
        public Status status() {
            return new Status(enabled.get() ? "Active" : "Disabled", null, RuntimeIdentity.processId(), WORLD,
                "c".repeat(32), 1, "0.1.0", "d".repeat(64), "");
        }
    }

    private static final class PollClock implements LongSupplier {
        final Gate gate;
        final AtomicBoolean entered = new AtomicBoolean();
        volatile Thread pollingThread;
        PollClock(Gate gate) { this.gate = gate; }
        public long getAsLong() {
            if (Thread.currentThread() == pollingThread && entered.compareAndSet(false, true)) gate.pause();
            return 100L;
        }
    }

    private static final class Gate {
        final CountDownLatch entered = new CountDownLatch(1), released = new CountDownLatch(1);
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        void pause() {
            entered.countDown();
            try {
                if (!released.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) throw new AssertionError("Fixture gate was not released");
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                var error = new AssertionError("Fixture gate interrupted", interrupted);
                failure.compareAndSet(null, error);
                throw error;
            } catch (AssertionError error) {
                failure.compareAndSet(null, error);
                throw error;
            }
        }
        void awaitEntered() throws InterruptedException { await(entered, "Worker did not enter its fixture gate"); }
        void open() { released.countDown(); }
    }

    @FunctionalInterface
    private interface Action { void run() throws Exception; }

    private static final class Worker {
        final Thread thread;
        final CountDownLatch started = new CountDownLatch(1), done = new CountDownLatch(1);
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        Worker(String name, Action action) {
            thread = new Thread(() -> {
                started.countDown();
                try { action.run(); }
                catch (Throwable error) { failure.set(error); }
                finally { done.countDown(); }
            }, "extension-concurrency-" + name);
            thread.setDaemon(true);
            thread.start();
        }
        void finish() throws InterruptedException {
            await(done, "Worker did not finish: " + thread.getName());
            thread.join(TimeUnit.SECONDS.toMillis(TIMEOUT_SECONDS));
            check(!thread.isAlive(), "Worker remained alive after completion: " + thread.getName());
            if (failure.get() != null) throw new AssertionError("Worker failed: " + thread.getName(), failure.get());
        }
        void returnsPromptly() throws InterruptedException {
            await(started, "Worker did not start");
            check(done.await(200, TimeUnit.MILLISECONDS), "Nonblocking operation waited for cleanup: " + thread.getName());
            finish();
        }
        void remainsBlocked() throws InterruptedException {
            await(started, "Worker did not start");
            check(!done.await(150, TimeUnit.MILLISECONDS), "Retirement completed before the admitted operation drained");
        }
    }

    private static final class Scope implements AutoCloseable {
        final List<Gate> gates = new ArrayList<>();
        final List<Worker> workers = new ArrayList<>();
        final List<ExtensionControl.Session> sessions = new ArrayList<>();
        Gate gate() { var gate = new Gate(); gates.add(gate); return gate; }
        Worker start(String name, Action action) { var worker = new Worker(name, action); workers.add(worker); return worker; }
        ExtensionControl.Session session(FixtureModules modules, LongSupplier clock) throws Exception {
            var session = new ExtensionControl.Session(null, zombie.GameWindow.class, clock, () -> modules);
            sessions.add(session);
            return session;
        }
        public void close() throws Exception {
            // Release every latch first, even when a negative assertion failed on an older implementation.
            for (Gate gate : gates) gate.open();
            Throwable failure = null;
            for (Worker worker : workers) {
                try { worker.finish(); }
                catch (Throwable error) { failure = append(failure, error); }
            }
            // Never block the test runner behind a worker whose lock failed to drain.
            boolean drained = workers.stream().noneMatch(worker -> worker.thread.isAlive());
            if (drained) for (ExtensionControl.Session session : sessions) session.close();
            for (Gate gate : gates) if (gate.failure.get() != null) failure = append(failure, gate.failure.get());
            if (failure != null) throw new AssertionError("Concurrency fixture cleanup failed", failure);
        }
        private static Throwable append(Throwable previous, Throwable next) {
            if (previous == null) return next;
            if (previous != next) previous.addSuppressed(next);
            return previous;
        }
    }

    private static void await(CountDownLatch latch, String message) throws InterruptedException {
        check(latch.await(TIMEOUT_SECONDS, TimeUnit.SECONDS), message);
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
