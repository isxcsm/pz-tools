package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.IOException;
import java.lang.reflect.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

/** B42.20: the original MCD thread clears its volatile save flag AFTER collision and population saving. */
final class NativeSaveWait implements SaveWaitHooks.Handler {
    private final Field instance, workerField, saveFlag;
    private final AtomicReference<Batch> active = new AtomicReference<>();
    NativeSaveWait(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> type = Class.forName("zombie.MapCollisionData", false, loader);
        Class<?> worker = Class.forName("zombie.MapCollisionData$MCDThread", false, loader);
        instance = type.getDeclaredField("instance");
        workerField = type.getDeclaredField("thread"); saveFlag = worker.getDeclaredField("save");
        if (!Modifier.isStatic(instance.getModifiers()) || workerField.getType() != worker
                || !Thread.class.isAssignableFrom(worker) || saveFlag.getType() != boolean.class
                || !Modifier.isVolatile(saveFlag.getModifiers()))
            throw new IllegalStateException("Unsupported native save completion layout");
        if (!instance.trySetAccessible() || !workerField.trySetAccessible() || !saveFlag.trySetAccessible())
            throw new IllegalAccessException("Native save completion is inaccessible");
    }
    Batch begin(SaveProvider.Context context, Consumer<Throwable> failure) throws IllegalAccessException {
        context.requireGameThread();
        Object owner = instance.get(null);
        if (owner == null) throw new IllegalStateException("Native save owner is unavailable");
        Batch batch = new Batch(context, owner, failure);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Native save still owned");
        return batch;
    }
    @Override public void beforeSave(Object operation) {
        Batch batch = active.get();
        if (batch == null) return;
        // This also fences nested/direct saves before their beginSaveRealZombies can replace native input.
        batch.awaitSettled();
        if (!batch.capturing || batch.entered || operation != batch.owner
                || Thread.currentThread() != batch.context.gameThread()) return;
        batch.entered = true;
        try {
            batch.worker = (Thread)workerField.get(operation);
            // A pre-existing request has no acknowledgement identity for us. Retain the original wait.
            batch.eligible = batch.worker != null && batch.worker.isAlive() && !saveFlag.getBoolean(batch.worker);
        } catch (IllegalAccessException failure) { batch.fail(failure); }
    }
    @Override public boolean deferWait(Object operation) {
        Batch batch = active.get();
        if (batch == null || !batch.capturing || !batch.eligible || batch.deferred
                || operation != batch.owner || Thread.currentThread() != batch.context.gameThread()) return false;
        try {
            if (workerField.get(operation) != batch.worker) return false;
            // Called only AFTER the original flag=true + notifier notification. Never posts a save itself.
            batch.deferred = true;
            return true;
        } catch (IllegalAccessException failure) { batch.fail(failure); return false; }
    }
    @Override public void beforeStop(Object operation) { awaitBeforeWorldSave(); }
    void awaitBeforeWorldSave() {
        Batch batch = active.get();
        if (batch != null) batch.awaitSettled();
    }
    void recordError(Throwable failure) {
        Batch batch = active.get();
        if (batch == null || Thread.currentThread() != batch.worker || batch.settled) return;
        try {
            // runInner logs a failed native save with save still true; errors in later n_update are unrelated.
            if (saveFlag.getBoolean(batch.worker)) batch.fail(failure);
        } catch (IllegalAccessException unreadable) { batch.fail(unreadable); }
    }
    final class Batch {
        final SaveProvider.Context context;
        final Object owner;
        final Consumer<Throwable> failure;
        volatile Thread worker;
        volatile boolean capturing = true, deferred, settled;
        boolean entered, eligible;
        Batch(SaveProvider.Context context, Object owner, Consumer<Throwable> failure) {
            this.context = context; this.owner = owner; this.failure = failure;
        }
        void seal() { capturing = false; }
        void fail(Throwable error) { failure.accept(error); }
        private synchronized boolean completed() {
            if (settled) return true;
            try {
                if (!saveFlag.getBoolean(worker)) { settled = true; return true; }
                if (!worker.isAlive()) {
                    fail(new IOException("Native save worker exited without acknowledging its write"));
                    settled = true; return true; // Terminated thread cannot still be writing.
                }
            } catch (IllegalAccessException unreadable) {
                fail(unreadable);
                // Losing the observation is not completion; retain ownership until the worker is gone.
                if (!worker.isAlive()) { settled = true; return true; }
            }
            return false;
        }
        void awaitSettled() {
            if (!deferred) return;
            boolean interrupted = false;
            // Only the module completion worker or a later ordinary/exit save waits here.
            // Never stop the native thread, clear its flag, or release ownership on an arbitrary timeout.
            while (!completed()) {
                try { Thread.sleep(5); } catch (InterruptedException stoppedWaiting) { interrupted = true; }
            }
            if (interrupted) Thread.currentThread().interrupt();
        }
        void close() {
            awaitSettled();
            active.compareAndSet(this, null);
        }
    }
}
