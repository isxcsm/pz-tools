package pztools.extensions.runtime;

import pztools.extensions.api.*;
import java.io.*;
import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import java.lang.reflect.InvocationTargetException;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Force publication interleavings in an isolated copy of the real runtime, without production hooks. */
public final class ContinuousRuntimePublicationTest {
    private static final String RUNTIME = "pztools.extensions.runtime.ContinuousRuntime";
    // Package-private classes the runtime uses must share its isolated runtime package.
    private static final String CATALOGUE = "pztools.extensions.runtime.Catalogue";
    private static CountDownLatch boundaryEntered, boundaryReleased;
    private enum Race {
        AFTER_PUBLICATION("after current.set"), BEFORE_REPORT("before initial report assignment"),
        STALE_FAULT("game-thread fault report against retirement");
        final String description;
        Race(String description) { this.description = description; }
    }

    static void run(Path root, Object world, String worldId, ClassLoader gameClasses) throws Exception {
        AssertionError failures = null;
        for (Race race : Race.values()) {
            ClassLoader isolated = new ClassLoader(ContinuousRuntimePublicationTest.class.getClassLoader()) {
                @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                    if (!name.equals(RUNTIME) && !name.startsWith(RUNTIME + "$") && !name.equals(CATALOGUE) && !name.startsWith(CATALOGUE + "$")
                            && !name.equals(ContinuousRuntimePublicationTest.class.getName()))
                        return super.loadClass(name, resolve);
                    synchronized (getClassLoadingLock(name)) {
                        Class<?> type = findLoadedClass(name);
                        if (type == null) {
                            try (var input = getParent().getResourceAsStream(name.replace('.', '/') + ".class")) {
                                if (input == null) throw new ClassNotFoundException(name);
                                byte[] bytes = input.readAllBytes();
                                if (name.equals(RUNTIME)) bytes = race == Race.STALE_FAULT ? withHeldReport(bytes) : withBoundary(bytes, race == Race.AFTER_PUBLICATION);
                                type = defineClass(name, bytes, 0, bytes.length);
                            } catch (IOException failure) { throw new ClassNotFoundException(name, failure); }
                        }
                        if (resolve) resolveClass(type);
                        return type;
                    }
                }
            };
            try {
                isolated.loadClass(ContinuousRuntimePublicationTest.class.getName())
                    .getMethod(race == Race.STALE_FAULT ? "exerciseStaleFault" : "exercise", Path.class, Object.class, String.class, ClassLoader.class)
                    .invoke(null, root, world, worldId, gameClasses);
            } catch (InvocationTargetException failure) {
                if (failures == null) failures = new AssertionError("Generation publication interleavings failed");
                failures.addSuppressed(new AssertionError("Generation publication race " + race.description, failure.getCause()));
            }
        }
        if (failures != null) throw failures;
        System.out.println("PASS: continuous generation publication/report interleavings, a stale fault report, and subsequent config/OFF");
    }

    private static byte[] withBoundary(byte[] bytes, boolean afterPublication) {
        var inserted = new AtomicInteger();
        var format = ClassFile.of();
        byte[] result = format.transformClass(format.parse(bytes), ClassTransform.transformingMethodBodies(
            method -> method.methodName().equalsString("apply"), (builder, element) -> {
                boolean publication = element instanceof InvokeInstruction call
                    && call.owner().asInternalName().equals("java/util/concurrent/atomic/AtomicReference")
                    && call.name().equalsString("set");
                boolean report = element instanceof FieldInstruction field && field.opcode() == Opcode.PUTFIELD
                    && field.owner().asInternalName().equals(RUNTIME.replace('.', '/')) && field.name().equalsString("report");
                if (afterPublication) builder.with(element);
                if (afterPublication ? publication : report) {
                    builder.invokestatic(ClassDesc.of(ContinuousRuntimePublicationTest.class.getName()),
                        "awaitGameTick", MethodTypeDesc.of(ConstantDescs.CD_void));
                    inserted.incrementAndGet();
                }
                if (!afterPublication) builder.with(element);
            }));
        check(afterPublication ? inserted.get() == 1 : inserted.get() > 0, "Publication boundary was not instrumented");
        return result;
    }

    /** Holds the game thread inside the report lock, after it has taken it and before it checks the generation. */
    private static byte[] withHeldReport(byte[] bytes) {
        var inserted = new AtomicInteger();
        var format = ClassFile.of();
        byte[] result = format.transformClass(format.parse(bytes), ClassTransform.transformingMethodBodies(
            method -> method.methodName().equalsString("publish"), (builder, element) -> {
                builder.with(element);
                if (element instanceof MonitorInstruction monitor && monitor.opcode() == Opcode.MONITORENTER) {
                    builder.invokestatic(ClassDesc.of(ContinuousRuntimePublicationTest.class.getName()),
                        "awaitGameTick", MethodTypeDesc.of(ConstantDescs.CD_void));
                    inserted.incrementAndGet();
                }
            }));
        check(inserted.get() == 1, "Report lock was not instrumented");
        return result;
    }

    public static void awaitGameTick() throws InterruptedException {
        // Only the first successful APPLY's publication is held, not subsequent configuration updates.
        if (boundaryEntered.getCount() == 0) return;
        boundaryEntered.countDown();
        check(boundaryReleased.await(5, TimeUnit.SECONDS), "Game tick did not release publication");
    }

    public static void exercise(Path root, Object world, String worldId, ClassLoader gameClasses) throws Exception {
        boundaryEntered = new CountDownLatch(1); boundaryReleased = new CountDownLatch(1);
        ContinuousRuntimeTest.ready = true;
        var runtime = new ContinuousRuntime(root);
        var context = new ContinuousProvider.Context(RuntimeIdentity.processId(), worldId, world,
            Thread.currentThread(), gameClasses, new AtomicBoolean(true));
        var failure = new AtomicReference<Throwable>();
        Thread controller = new Thread(() -> {
            try { runtime.apply(request(worldId, -1, 30, "published"), null, gameClasses, "42.20"); }
            catch (Throwable error) { failure.set(error); }
        }, "continuous-publication-controller");
        try {
            controller.start();
            check(boundaryEntered.await(5, TimeUnit.SECONDS), "Initial APPLY did not reach publication");
            runtime.tick(context);
            boundaryReleased.countDown(); controller.join(5000);
            check(!controller.isAlive() && failure.get() == null, "Initial APPLY failed: " + failure.get());
            runtime.tick(context); // A callback that already cleared pending must retain its acknowledgement.
            var active = runtime.status();
            check(active.state().equals("Active") && active.reason() == null && active.appliedRevision() == 30
                && "published".equals(ContinuousRuntimeTest.appliedValue) && ControlPoints.call("fixture", null, 1, 0) == 5,
                "Initial Pending report overwrote completed activation: " + active);
            var next = runtime.apply(request(worldId, active.appliedRevision(), 31, "updated"), null, gameClasses, "42.20");
            check(next.state().equals("Pending") && "safe-boundary".equals(next.reason()),
                "Published revision caused a false configuration conflict: " + next);
            runtime.tick(context);
            check(runtime.status().state().equals("Active") && runtime.status().appliedRevision() == 31
                && active.generation().equals(runtime.status().generation()) && "updated".equals(ContinuousRuntimeTest.appliedValue),
                "Configuration update did not recover on the same generation");
            check(runtime.deactivate("publication-test-off").state().equals("Disabled")
                && ControlPoints.call("fixture", null, 1, 0) == 0, "OFF did not retire the published generation");
        } finally {
            boundaryReleased.countDown(); controller.join(5000); runtime.close();
        }
    }

    /**
     * The game thread finds the provider faulted and is about to report it when the connection thread
     * retires that generation and publishes the next one. Retirement must wait for the report, so the stale
     * FaultedPassThrough lands first and the new generation's Pending is what stays.
     */
    public static void exerciseStaleFault(Path root, Object world, String worldId, ClassLoader gameClasses) throws Exception {
        boundaryEntered = new CountDownLatch(1); boundaryReleased = new CountDownLatch(1);
        ContinuousRuntimeTest.ready = true;
        var runtime = new ContinuousRuntime(root);
        var context = new ContinuousProvider.Context(RuntimeIdentity.processId(), worldId, world,
            Thread.currentThread(), gameClasses, new AtomicBoolean(true));
        var failure = new AtomicReference<Throwable>();
        var replaced = new AtomicReference<ContinuousModules.Status>();
        Thread game = new Thread(() -> {
            try { runtime.tick(context); } catch (Throwable error) { failure.set(error); }
        }, "continuous-stale-fault-game");
        Thread controller = new Thread(() -> {
            try {
                runtime.deactivate("replaced");
                replaced.set(runtime.apply(request(worldId, -1, 41, "next"), null, gameClasses, "42.20"));
            } catch (Throwable error) { failure.set(error); }
        }, "continuous-stale-fault-controller");
        try {
            boundaryEntered.countDown(); // The healthy activation below reports without holding.
            runtime.apply(request(worldId, -1, 40, "first"), null, gameClasses, "42.20"); runtime.tick(context);
            String first = runtime.status().generation();
            check(runtime.status().state().equals("Active"), "Fixture generation did not activate");
            boundaryEntered = new CountDownLatch(1);
            ContinuousRuntimeTest.failHealth = true;
            game.start();
            check(boundaryEntered.await(5, TimeUnit.SECONDS), "Game thread did not reach the fault report");
            ContinuousRuntimeTest.failHealth = false;
            controller.start();
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (controller.getState() != Thread.State.BLOCKED && controller.isAlive() && System.nanoTime() < deadline) Thread.onSpinWait();
            check(controller.getState() == Thread.State.BLOCKED, "Retirement did not wait for the game thread's report");
            boundaryReleased.countDown(); game.join(5000); controller.join(5000);
            check(!game.isAlive() && !controller.isAlive() && failure.get() == null, "Stale fault race failed: " + failure.get());
            var status = runtime.status();
            check(replaced.get() != null && replaced.get().state().equals("Pending") && status.state().equals("Pending")
                && "safe-boundary".equals(status.reason()) && !first.equals(status.generation()),
                "A stale fault report overwrote the next generation: " + status);
        } finally {
            ContinuousRuntimeTest.failHealth = false;
            boundaryReleased.countDown(); game.join(5000); controller.join(5000); runtime.close();
        }
    }

    private static ContinuousModules.Apply request(String worldId, long expected, long revision, String value) {
        return new ContinuousModules.Apply(RuntimeIdentity.processId(), worldId, expected, revision,
            "fixture.vehicle", false, Map.of("value", value));
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
