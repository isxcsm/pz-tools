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
                scope.ticket = batch != null && batch.armed ? batch : null;
            }
            public void exit(Throwable failure) {
                Scope scope = scopes.get();
                try {
                    Batch current = active.get();
                    if (failure != null && current != null) current.fail(failure);
                    if (failure == null && scope.depth == 1 && scope.ticket != null) scope.ticket.acknowledge(bit);
                } finally {
                    if (--scope.depth == 0) scope.ticket = null;
                    drainDepth.set(Math.max(0, drainDepth.get() - 1));
                }
            }
        };
    }
    private static final class Scope { Batch ticket; int depth; }
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
    Batch begin(SaveProvider.Context context, boolean includePlayers) {
        context.requireGameThread();
        Batch batch = new Batch(context, includePlayers ? 3 : 2);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Previous save is still draining");
        return batch;
    }
    final class Batch implements SaveProvider.PreparedSave {
        private final SaveProvider.Context context;
        private final AtomicInteger pending;
        private final CountDownLatch drained = new CountDownLatch(1);
        private final AtomicReference<Throwable> failure = new AtomicReference<>();
        private volatile boolean capturing = true, armed, closing;
        DeferredChunkWrites.Batch chunks;
        Batch(SaveProvider.Context context, int expected) { this.context = context; pending = new AtomicInteger(expected); }
        void arm() { if (chunks != null) chunks.seal(); capturing = false; armed = true; }
        void fail(Throwable error) { if (error != null) failure.compareAndSet(null, error); }
        void acknowledge(int bit) {
            if (pending.updateAndGet(value -> value & ~bit) == 0) {
                drained.countDown();
                if (closing) active.compareAndSet(this, null);
            }
        }
        public long retainedBytes() { return chunks == null ? 0 : chunks.retainedBytes(); }
        public SaveProvider.Completion completion() { return chunks == null ? SaveProvider.Completion.GAME_SAVE_AND_DATABASE_QUEUES_DRAINED : SaveProvider.Completion.GAME_SAVE_AND_PENDING_WRITES_DRAINED; }
        public void commit() throws Exception {
            if (chunks != null) chunks.await();
            while (!drained.await(100, TimeUnit.MILLISECONDS)) {
                if (!context.worldValid().get()) throw new IOException("World changed before database writes were confirmed");
            }
            if (!context.worldValid().get()) throw new IOException("World changed during save");
            Throwable problem = failure.get();
            if (problem != null) throw new IOException("Game reported a save/write error", problem);
        }
        public void close() throws Exception {
            // Even cancellation/world exit must not leave detached writes behind a released save owner.
            if (chunks != null) chunks.await();
            closing = true;
            // Interrupted waiting does not release admission while native game writes are unresolved.
            if (drained.getCount() == 0 || !context.worldValid().get()) active.compareAndSet(this, null);
        }
    }
}
