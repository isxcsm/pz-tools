package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.IOException;
import java.lang.reflect.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.*;
import java.util.function.Consumer;

/** Private native-call handoff. Public save/stop are unchanged and retain their original locks. */
final class OwnedNativeSave {
    static final String POINT = "pztools.save.native-start.v1";
    private final Field workerField, saveFlag, saveLock, population;
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private final ThreadLocal<Batch> nativePhase = new ThreadLocal<>();
    private final GameHooks.Observer observer = new GameHooks.Observer() {
        public void enter() {
            Batch batch = active.get();
            if (batch != null && batch.eligible && !batch.acknowledged && Thread.currentThread() == batch.worker) {
                nativePhase.set(batch); batch.started = true;
            }
        }
        public void exit(Throwable problem) {
            Batch batch = nativePhase.get(); nativePhase.remove();
            if (batch == null) return;
            if (problem == null) batch.acknowledged = true;
            else batch.fail(problem); // A retry may settle it; failure is never erased by that retry.
        }
    };
    OwnedNativeSave(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> collision = Class.forName("zombie.MapCollisionData", false, loader);
        workerField = collision.getDeclaredField("thread");
        saveFlag = workerField.getType().getDeclaredField("save");
        Class<?> populationType = Class.forName("zombie.popman.ZombiePopulationManager", false, loader);
        saveLock = populationType.getDeclaredField("saveLock"); population = populationType.getField("instance");
        if (!Thread.class.isAssignableFrom(workerField.getType()) || saveFlag.getType() != boolean.class
                || !Modifier.isVolatile(saveFlag.getModifiers()) || saveLock.getType() != ReentrantLock.class
                || !workerField.trySetAccessible() || !saveFlag.trySetAccessible() || !saveLock.trySetAccessible())
            throw new IllegalAccessException("Unsupported native ownership contract");
    }
    void register() { GameHooks.register(POINT, observer); }
    void unregister() { GameHooks.unregister(POINT, observer); }
    Batch begin(SaveProvider.Context context, Consumer<Throwable> report) {
        context.requireGameThread();
        Batch batch = new Batch(context, report);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Native save already owned");
        return batch;
    }
    public void before(Object owner) throws Exception {
        Batch batch = active.get();
        if (batch == null) throw new IllegalStateException("No private native capture");
        batch.context.requireGameThread();
        if (batch.entered) throw new IllegalStateException("Duplicate private native request");
        batch.entered = true; batch.owner = owner;
        batch.worker = (Thread)workerField.get(owner);
        batch.eligible = population.get(null) != null && population.get(null).getClass() == population.getType() && batch.worker != null && batch.worker.isAlive() && !saveFlag.getBoolean(batch.worker);
    }
    public boolean defer(Object owner) throws Exception {
        Batch batch = active.get();
        if (batch == null || !batch.eligible || batch.attempted || owner != batch.owner) return false;
        batch.context.requireGameThread();
        if (workerField.get(owner) != batch.worker) return false;
        batch.attempted = true;
        var ready = new CompletableFuture<Void>();
        batch.settled = new CompletableFuture<>();
        try {
            Thread.ofVirtual().name("PzTools-native-save-owner").inheritInheritableThreadLocals(false)
                .start(() -> batch.own(ready));
        } catch (RuntimeException | Error failure) {
            batch.settled = null; batch.fail(failure); return false; // No owner: original wait remains.
        }
        batch.waitFor(ready);
        return true;
    }
    final class Batch {
        final SaveProvider.Context context;
        final Consumer<Throwable> report;
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        Object owner;
        volatile Thread worker;
        volatile boolean entered, eligible, started, attempted, acknowledged;
        CompletableFuture<Void> settled;
        Batch(SaveProvider.Context context, Consumer<Throwable> report) { this.context = context; this.report = report; }
        void fail(Throwable problem) {
            if (failure.compareAndSet(null, problem)) {
                try { report.accept(problem); } catch (Throwable reporting) { if (reporting != problem) problem.addSuppressed(reporting); }
            }
        }
        boolean pending() throws Exception {
            if (acknowledged) return false;
            if (!worker.isAlive()) throw new IOException("Native worker exited without completing the requested save");
            // An observed request needs its own exit receipt. A subsequent save flag cannot acknowledge it.
            if (started) return true;
            try { return saveFlag.getBoolean(worker); }
            catch (IllegalAccessException lostObservation) {
                fail(lostObservation); return true; // Losing observation is not proof that native work finished.
            }
        }
        void own(CompletableFuture<Void> ready) {
            ReentrantLock lock = null;
            boolean held = false, interrupted = false;
            try {
                // Taking saveLock BEFORE the worker reaches n_save can deadlock an earlier
                // processPendingSaveCells call. Wait for the exact observed native entry first.
                while (!started && pending()) {
                    try { Thread.sleep(1); } catch (InterruptedException signal) { interrupted = true; }
                }
                if (pending()) {
                    lock = (ReentrantLock)saveLock.get(null); lock.lock(); held = true;
                }
                // Original beginSaveRealZombies / requestSaveCell use this same lock.
                // Their input cannot replace our native snapshot while its write is running.
                ready.complete(null);
                while (pending()) {
                    try { Thread.sleep(5); } catch (InterruptedException signal) { interrupted = true; }
                }
            } catch (Throwable problem) { fail(problem); ready.completeExceptionally(problem); }
            finally {
                try { if (held) lock.unlock(); } catch (Throwable problem) { fail(problem); }
                finally {
                    settled.complete(null);
                    if (interrupted) Thread.currentThread().interrupt();
                }
            }
        }
        void waitFor(CompletableFuture<Void> future) throws IOException {
            boolean interrupted = false;
            try {
                while (true) {
                    try { future.get(); return; }
                    catch (InterruptedException signal) { interrupted = true; }
                    catch (ExecutionException problem) { throw new IOException("Native save handoff failed", problem.getCause()); }
                }
            } finally { if (interrupted) Thread.currentThread().interrupt(); }
        }
        void await() throws IOException {
            if (settled != null) waitFor(settled);
            if (failure.get() != null) throw new IOException("Native save failed after owned work settled", failure.get());
        }
        void close() throws IOException {
            try { await(); } finally { active.compareAndSet(this, null); }
        }
    }
}