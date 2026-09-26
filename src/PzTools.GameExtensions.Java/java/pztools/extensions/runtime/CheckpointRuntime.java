package pztools.extensions.runtime;

import pztools.extensions.api.SaveProvider;
import java.util.Objects;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** One owned save: reserve completion capacity before capture, including failure cleanup. */
public final class CheckpointRuntime implements AutoCloseable {
    public enum Phase { CAPTURING, QUEUED, WRITING, COMMITTED, FAILED, CANCELLED }
    public record Result(String requestId, String sessionId, String worldId, Phase phase, Throwable error) { }
    private final long maximumBytes;
    private final AtomicReference<Job> active = new AtomicReference<>();
    private final AtomicBoolean closed = new AtomicBoolean();
    private final ExecutorService writer = new ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(1), runnable -> {
            Thread thread = new Thread(runnable, "PzTools-checkpoint-writer");
            thread.setDaemon(true); return thread;
        }, new ThreadPoolExecutor.AbortPolicy());

    public CheckpointRuntime(long maximumBytes) {
        if (maximumBytes < 1) throw new IllegalArgumentException("A finite capture budget is required");
        this.maximumBytes = maximumBytes;
    }
    public Job begin(SaveProvider provider, SaveProvider.Context context) throws Exception {
        Objects.requireNonNull(provider); context.requireGameThread();
        if (closed.get()) throw new IllegalStateException("Runtime is closed");
        var support = provider.inspect(context);
        if (!support.supported()) throw new UnsupportedOperationException(support.reason());
        var job = new Job(context);
        if (!active.compareAndSet(null, job)) throw new IllegalStateException("A checkpoint is already owned");
        try {
            // Rejection occurs BEFORE touching the world. Shutdown cannot strand post-capture cleanup.
            writer.execute(() -> complete(job));
        } catch (RuntimeException | Error rejected) {
            finish(job, Phase.FAILED, rejected); throw rejected;
        }
        try {
            job.snapshot = Objects.requireNonNull(provider.capture(context, maximumBytes));
            // Diagnostics are optional. Their failure must not abandon an already-owned save.
            try {
                String detail = job.snapshot.diagnostics();
                job.diagnostics = detail == null ? "" : detail.substring(0, Math.min(detail.length(), 2048));
            } catch (RuntimeException ignored) { job.diagnostics = "diagnostics-unavailable"; }
            long bytes = job.snapshot.retainedBytes();
            if (bytes < 0 || bytes > maximumBytes)
                throw new IllegalStateException("Capture exceeds the configured memory budget");
        } catch (Throwable failure) { job.captureFailure = failure; }
        finally {
            job.phase = Phase.QUEUED;
            job.captured.countDown();
        }
        // Once capture begins, failure also has an owned asynchronous completion; no synchronous close/join.
        return job;
    }
    private void complete(Job job) {
        boolean interrupted = false;
        while (true) {
            try { job.captured.await(); break; }
            catch (InterruptedException signal) { interrupted = true; }
        }
        Phase terminal = job.captureFailure == null ? Phase.CANCELLED : Phase.FAILED;
        Throwable error = job.captureFailure;
        SaveProvider.PreparedSave snapshot = job.snapshot;
        try {
            if (error == null && job.beginWriting()) {
                snapshot.commit(); job.completion = snapshot.completion(); terminal = Phase.COMMITTED;
            }
        } catch (Throwable failure) { terminal = Phase.FAILED; error = failure; }
        finally {
            try { if (snapshot != null) snapshot.close(); }
            catch (Throwable failure) {
                if (error == null) error = failure; else error.addSuppressed(failure);
                terminal = Phase.FAILED;
            }
            job.snapshot = null;
            finish(job, terminal, error);
            if (interrupted) Thread.currentThread().interrupt();
        }
    }
    private void finish(Job job, Phase phase, Throwable failure) {
        job.phase = phase;
        active.compareAndSet(job, null);
        job.result = new Result(job.context.requestId(), job.context.sessionId(), job.context.worldId(), phase, failure);
    }
    /** True only after capture, commit and close have released their ownership. */
    public boolean isIdle() { return active.get() == null; }
    public boolean awaitTermination(long milliseconds) throws InterruptedException {
        return writer.awaitTermination(milliseconds, TimeUnit.MILLISECONDS);
    }
    /** Stops admission. Submitted capture/cleanup drains without interruption. */
    @Override public void close() { if (closed.compareAndSet(false, true)) writer.shutdown(); }

    public static final class Job implements pztools.extensions.api.SaveTask {
        private final SaveProvider.Context context;
        private final CountDownLatch captured = new CountDownLatch(1);
        private SaveProvider.PreparedSave snapshot;
        private Throwable captureFailure;
        private volatile Phase phase = Phase.CAPTURING;
        private volatile CheckpointRuntime.Result result;
        private volatile String diagnostics = "";
        @Override public String diagnostics() { return diagnostics; }
        private volatile SaveProvider.Completion completion = SaveProvider.Completion.DETACHED_WRITES_COMMITTED;
        private boolean cancelled;
        private Job(SaveProvider.Context context) { this.context = context; }
        private synchronized boolean beginWriting() {
            if (cancelled) return false;
            phase = Phase.WRITING; return true;
        }
        public Phase phase() { return phase; }
        @Override public pztools.extensions.api.SaveTask.Result completed() {
            CheckpointRuntime.Result value = result;
            return value == null ? null : new pztools.extensions.api.SaveTask.Result(value.requestId(), value.sessionId(),
                value.worldId(), completion, value.error(), value.phase() == Phase.CANCELLED);
        }
        public CheckpointRuntime.Result poll() { return result; }
        public synchronized boolean cancelBeforeWrite() {
            if (phase != Phase.QUEUED) return false;
            cancelled = true; return true;
        }
    }
}