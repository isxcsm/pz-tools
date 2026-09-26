package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.IOException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Completion tickets, not queue-length guesses. A drain must START after capture is armed. */
final class SaveSignals {
    static final String THUMBNAIL = "pztools.save.thumbnail.v1";
    static final String PLAYERS = "pztools.save.players-drain.v1";
    static final String VEHICLES = "pztools.save.vehicles-drain.v1";
    static final String ERRORS = "pztools.save.error.v1";
    NativeSaveWait nativeWait;
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private final ThreadLocal<Integer> drainDepth = ThreadLocal.withInitial(() -> 0);
    private final GameHooks.Observer thumbnail = new GameHooks.Observer() {
        public boolean suppress() {
            Batch batch = active.get();
            return batch != null && batch.capturing && Thread.currentThread() == batch.context.gameThread();
        }
    };
    private final GameHooks.Observer players = drain(1);
    private final GameHooks.Observer vehicles = drain(2);
    private final GameHooks.Observer errors = new GameHooks.Observer() {
        public void error(Throwable failure) {
            if (nativeWait != null) nativeWait.recordError(failure);
            Batch batch = active.get();
            if (batch != null && (drainDepth.get() > 0 || batch.capturing
                    && Thread.currentThread() == batch.context.gameThread())) batch.fail(failure);
        }
    };
    private GameHooks.Observer drain(int bit) {
        return new GameHooks.Observer() {
            private final ThreadLocal<Scope> scopes = ThreadLocal.withInitial(Scope::new);
            public void enter() {
                Scope scope = scopes.get();
                drainDepth.set(drainDepth.get() + 1);
                if (scope.depth++ != 0) return;
                Batch batch = active.get();
                scope.ticket = batch;
                scope.acknowledge = batch != null && batch.armed;
                if (batch != null) batch.enterDrain();
            }
            public void exit(Throwable failure) {
                Scope scope = scopes.get();
                try {
                    Batch current = active.get();
                    if (failure != null && current != null) current.fail(failure);
                    if (failure == null && scope.depth == 1 && scope.ticket != null && scope.acknowledge)
                        scope.ticket.acknowledge(bit);
                } finally {
                    if (--scope.depth == 0) {
                        if (scope.ticket != null) scope.ticket.exitDrain();
                        scope.ticket = null;
                    }
                    drainDepth.set(Math.max(0, drainDepth.get() - 1));
                }
            }
        };
    }
    private static final class Scope { Batch ticket; int depth; boolean acknowledge; }
    void register() {
        try {
            GameHooks.register(THUMBNAIL, thumbnail); GameHooks.register(PLAYERS, players);
            GameHooks.register(VEHICLES, vehicles); GameHooks.register(ERRORS, errors);
        } catch (RuntimeException failure) { unregister(); throw failure; }
    }
    void unregister() {
        GameHooks.unregister(THUMBNAIL, thumbnail); GameHooks.unregister(PLAYERS, players);
        GameHooks.unregister(VEHICLES, vehicles); GameHooks.unregister(ERRORS, errors);
    }
    Batch begin(SaveProvider.Context context, boolean includePlayers) { return begin(context, includePlayers, null); }
    Batch begin(SaveProvider.Context context, boolean includePlayers, Thread databaseWorker) {
        context.requireGameThread();
        Batch batch = new Batch(context, includePlayers ? 3 : 2, databaseWorker);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Previous save is still draining");
        return batch;
    }
    final class Batch implements SaveProvider.PreparedSave {
        private final SaveProvider.Context context;
        private final AtomicInteger pending;
        private final Object databaseGate = new Object();
        private final Thread databaseWorker;
        private int inFlight;
        private final AtomicReference<Throwable> failure = new AtomicReference<>();
        private volatile boolean capturing = true, armed;
        DeferredChunkWrites.Batch chunks;
        NativeSaveWait.Batch nativeSave;
        Batch(SaveProvider.Context context, int expected, Thread databaseWorker) {
            this.context = context; this.databaseWorker = databaseWorker; pending = new AtomicInteger(expected);
        }
        void arm() { if (chunks != null) chunks.seal(); if (nativeSave != null) nativeSave.seal(); capturing = false; armed = true; }
        void fail(Throwable error) { if (error != null) failure.compareAndSet(null, error); }
        void enterDrain() { synchronized (databaseGate) { inFlight++; } }
        void exitDrain() { synchronized (databaseGate) { inFlight--; databaseGate.notifyAll(); } }
        void acknowledge(int bit) {
            pending.updateAndGet(value -> value & ~bit);
            synchronized (databaseGate) { databaseGate.notifyAll(); }
        }
        private boolean awaitDatabase() {
            boolean interrupted = Thread.interrupted();
            synchronized (databaseGate) {
                while (pending.get() != 0 || inFlight != 0) {
                    if (inFlight == 0 && databaseWorker != null && !databaseWorker.isAlive()) {
                        fail(new IOException("Database worker stopped before acknowledging captured writes"));
                        break;
                    }
                    // No lifetime signal exists in standalone hook fixtures. Never abandon an observed in-flight call.
                    if (inFlight == 0 && databaseWorker == null && !context.worldValid().get()) break;
                    try { databaseGate.wait(25); } catch (InterruptedException stop) { interrupted = true; }
                }
            }
            if (interrupted) Thread.currentThread().interrupt();
            return interrupted;
        }
        public long retainedBytes() { return chunks == null ? 0 : chunks.retainedBytes(); }
        public SaveProvider.Completion completion() { return chunks == null ? SaveProvider.Completion.GAME_SAVE_AND_DATABASE_QUEUES_DRAINED : SaveProvider.Completion.GAME_SAVE_AND_PENDING_WRITES_DRAINED; }
        public void commit() throws Exception {
            if (chunks != null) chunks.await();
            if (nativeSave != null) nativeSave.awaitSettled();
            if (awaitDatabase()) throw new InterruptedException("Interrupted after draining owned database writes");
            if (!context.worldValid().get()) throw new IOException("World changed during save");
            Throwable problem = failure.get();
            if (problem != null) throw new IOException("Game reported a save/write error", problem);
        }
        public void close() throws Exception {
            // Even cancellation/world exit must not leave detached writes behind a released save owner.
            try { if (chunks != null) chunks.await(); }
            finally {
                if (nativeSave != null) nativeSave.close();
                // World invalidation is an error, not proof that a database thread stopped writing.
                awaitDatabase();
                active.compareAndSet(this, null);
            }
        }
    }
}
