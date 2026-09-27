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
    private static CountDownLatch boundaryEntered, boundaryReleased;

    static void run(Path root, Object world, String worldId, ClassLoader gameClasses) throws Exception {
        AssertionError failures = null;
        for (boolean afterPublication : new boolean[] { true, false }) {
            ClassLoader isolated = new ClassLoader(ContinuousRuntimePublicationTest.class.getClassLoader()) {
                @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                    if (!name.equals(RUNTIME) && !name.startsWith(RUNTIME + "$")
                            && !name.equals(ContinuousRuntimePublicationTest.class.getName()))
                        return super.loadClass(name, resolve);
                    synchronized (getClassLoadingLock(name)) {
                        Class<?> type = findLoadedClass(name);
                        if (type == null) {
                            try (var input = getParent().getResourceAsStream(name.replace('.', '/') + ".class")) {
                                if (input == null) throw new ClassNotFoundException(name);
                                byte[] bytes = input.readAllBytes();
                                if (name.equals(RUNTIME)) bytes = withBoundary(bytes, afterPublication);
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
                    .getMethod("exercise", Path.class, Object.class, String.class, ClassLoader.class)
                    .invoke(null, root, world, worldId, gameClasses);
            } catch (InvocationTargetException failure) {
                if (failures == null) failures = new AssertionError("Generation publication interleavings failed");
                failures.addSuppressed(new AssertionError("Generation publication race "
                    + (afterPublication ? "after current.set" : "before initial report assignment"), failure.getCause()));
            }
        }
        if (failures != null) throw failures;
        System.out.println("PASS: continuous generation publication/report interleavings and subsequent config/OFF");
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
                && "published".equals(ContinuousRuntimeTest.appliedValue) && VehicleHooks.tryControl(null, 1, 0) == 5,
                "Initial Pending report overwrote completed activation: " + active);
            var next = runtime.apply(request(worldId, active.appliedRevision(), 31, "updated"), null, gameClasses, "42.20");
            check(next.state().equals("Pending") && "safe-boundary".equals(next.reason()),
                "Published revision caused a false configuration conflict: " + next);
            runtime.tick(context);
            check(runtime.status().state().equals("Active") && runtime.status().appliedRevision() == 31
                && active.generation().equals(runtime.status().generation()) && "updated".equals(ContinuousRuntimeTest.appliedValue),
                "Configuration update did not recover on the same generation");
            check(runtime.deactivate("publication-test-off").state().equals("Disabled")
                && VehicleHooks.tryControl(null, 1, 0) == 0, "OFF did not retire the published generation");
        } finally {
            boundaryReleased.countDown(); controller.join(5000); runtime.close();
        }
    }

    private static ContinuousModules.Apply request(String worldId, long expected, long revision, String value) {
        return new ContinuousModules.Apply(RuntimeIdentity.processId(), worldId, expected, revision,
            "fixture.vehicle", false, Map.of("value", value));
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
