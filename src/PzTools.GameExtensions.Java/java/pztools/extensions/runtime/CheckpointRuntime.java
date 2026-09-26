package pztools.extensions.runtime;

import pztools.extensions.api.SaveProvider;
import java.util.Objects;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** A single owned save operation. No disk wait, worker join or completion callback on the game thread. */
public final class CheckpointRuntime implements AutoCloseable {
    public enum Phase { CAPTURING, QUEUED, WRITING, COMMITTED, FAILED, CANCELLED }
    public record Result(String requestId, String sessionId, String worldId, Phase phase, Throwable error) { }
    private final long maximumBytes;
    private final AtomicReference<Job> active = new AtomicReference<>();
    private final AtomicBoolean closed = new AtomicBoolean();
    private final ExecutorService writer = new ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(1), runnable -> {
            Thread thread = new Thread(runnable, "PzTools-checkpoint-writer");
            thread.setDaemon(true);
            return thread;
        }, new ThreadPoolExecutor.AbortPolicy());

    public CheckpointRuntime(long maximumBytes) {
        if (maximumBytes < 1) throw new IllegalArgumentException("A finite capture budget is required");
        this.maximumBytes = maximumBytes;
    }

    public Job begin(SaveProvider provider, SaveProvider.Context context) throws Exception {
        Objects.requireNonNull(provider);
        context.requireGameThread();
        if (closed.get()) throw new IllegalStateException("Runtime is closed");
        var support = provider.inspect(context);
        if (!support.supported()) throw new UnsupportedOperationException(support.reason());
        var job = new Job(context);
        if (!active.compareAndSet(null, job)) throw new IllegalStateException("A checkpoint is already owned");
        SaveProvider.PreparedSave snapshot = null;
        try {
            // Only this phase reads mutable game state. The captured result must be detached.
            snapshot = Objects.requireNonNull(provider.capture(context, maximumBytes));
            if (snapshot.retainedBytes() < 0 || snapshot.retainedBytes() > maximumBytes)
                throw new IllegalStateException("Capture exceeds the configured memory budget");
            var owned = snapshot;
            job.phase = Phase.QUEUED;
            writer.execute(() -> commit(job, owned));
            return job;
        } catch (Throwable failure) {
            if (snapshot != null) {
                try { snapshot.close(); } catch (Throwable closeFailure) { failure.addSuppressed(closeFailure); }
            }
            finish(job, Phase.FAILED, failure);
            if (failure instanceof Exception exception) throw exception;
            throw (Error)failure;
        }
    }

    private void commit(Job job, SaveProvider.PreparedSave snapshot) {
        Phase terminal = Phase.CANCELLED;
        Throwable error = null;
        try {
            if (job.beginWriting()) {
                snapshot.commit();
                job.completion = snapshot.completion();
                terminal = Phase.COMMITTED;
            }
        } catch (Throwable failure) { terminal = Phase.FAILED; error = failure; }
        finally {
            try { snapshot.close(); }
            catch (Throwable failure) {
                if (error == null) error = failure; else error.addSuppressed(failure);
                terminal = Phase.FAILED;
            }
            // Ownership is retained until the writer AND snapshot cleanup have finished.
            finish(job, terminal, error);
        }
    }

    private void finish(Job job, Phase phase, Throwable failure) {
        job.phase = phase;
        active.compareAndSet(job, null);
        job.result = new Result(job.context.requestId(), job.context.sessionId(), job.context.worldId(), phase, failure);
    }

    /** Stops admission. Existing writes drain; shutdownNow/interrupt would not make their completion known. */
    @Override public void close() {
        if (closed.compareAndSet(false, true)) writer.shutdown();
    }

    public static final class Job implements pztools.extensions.api.SaveTask {
        private final SaveProvider.Context context;
        private volatile Phase phase = Phase.CAPTURING;
        private volatile CheckpointRuntime.Result result;
        private volatile SaveProvider.Completion completion = SaveProvider.Completion.DETACHED_WRITES_COMMITTED;
        private boolean cancelled;
        private Job(SaveProvider.Context context) { this.context = context; }
        private synchronized boolean beginWriting() {
            if (cancelled) return false;
            phase = Phase.WRITING;
            return true;
        }
        public Phase phase() { return phase; }
        @Override public pztools.extensions.api.SaveTask.Result completed() {
            CheckpointRuntime.Result value = result;
            return value == null ? null : new pztools.extensions.api.SaveTask.Result(value.requestId(), value.sessionId(),
                value.worldId(), completion, value.error(), value.phase() == Phase.CANCELLED);
        }
        /** Nonblocking observation. null means NOT completed, including a dequeued but still running write. */
        public CheckpointRuntime.Result poll() { return result; }
        public synchronized boolean cancelBeforeWrite() {
            if (phase != Phase.QUEUED) return false;
            cancelled = true;
            return true;
        }
    }
}
