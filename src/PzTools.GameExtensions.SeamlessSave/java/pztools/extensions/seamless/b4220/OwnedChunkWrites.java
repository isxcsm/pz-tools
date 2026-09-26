package pztools.extensions.seamless.b4220;

import pztools.extensions.api.SaveProvider;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.Arrays;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.Lock;
import java.util.function.Consumer;

/** Private-call-only immutable bytes. Original readers/writers keep their own unchanged game locks. */
final class OwnedChunkWrites implements AutoCloseable {
    static final int MAXIMUM_PENDING = 128;
    interface Access {
        File destination(int x, int y) throws Exception;
        LockReference reserve(int x, int y) throws Exception;
        void synchronous(int x, int y, ByteBuffer bytes) throws Exception;
    }
    interface LockReference extends AutoCloseable {
        Lock writeLock();
        @Override void close() throws Exception;
    }
    @FunctionalInterface interface Sink { void write(FileChannel file, byte[] bytes) throws IOException; }
    private final Access access;
    private final Sink sink;
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private final Object lifecycle = new Object();
    private boolean closed;
    // Lock ownership and disk execution have different lifetimes. Bounded virtual owners park while
    // ONE platform worker writes; the next independent chunk need not wait for the previous disk I/O.
    private final ExecutorService owners = Executors.newThreadPerTaskExecutor(Thread.ofVirtual()
        .name("PzTools-chunk-owner-", 0).inheritInheritableThreadLocals(false).factory());
    private final ThreadPoolExecutor writer = new ThreadPoolExecutor(1, 1, 5, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(MAXIMUM_PENDING), Thread.ofPlatform().daemon(true)
            .name("PzTools-owned-chunk-writer").inheritInheritableThreadLocals(false).factory(),
        new ThreadPoolExecutor.AbortPolicy());

    OwnedChunkWrites(Access access) { this(access, OwnedChunkWrites::writeBytes); }
    OwnedChunkWrites(Access access, Sink sink) {
        this.access = access; this.sink = sink; writer.allowCoreThreadTimeOut(true);
    }
    static void writeBytes(FileChannel file, byte[] bytes) throws IOException {
        file.truncate(0); file.position(0);
        ByteBuffer data = ByteBuffer.wrap(bytes);
        while (data.hasRemaining()) file.write(data);
    }
    Batch begin(SaveProvider.Context context, long limit, Consumer<Throwable> failure) {
        context.requireGameThread();
        if (limit < 1) throw new IllegalArgumentException("Positive byte budget required");
        synchronized (lifecycle) {
            if (closed) throw new IllegalStateException("Private writer is closed");
            Batch batch = new Batch(context, limit, failure);
            if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Private chunk writes are still owned");
            return batch;
        }
    }
    public void write(int x, int y, ByteBuffer bytes) throws Exception {
        Batch batch = active.get();
        if (batch == null || !batch.capturing) throw new IllegalStateException("No private save capture");
        batch.context.requireGameThread();
        File file = access.destination(x, y);
        Path path = file == null ? null : file.toPath().toAbsolutePath().normalize();
        if (path != null && !path.startsWith(batch.root)) throw new IOException("Chunk destination left the selected world");
        int size = bytes.position();
        // First-file publication stays synchronous. No placeholders or changed vanilla existence checks.
        boolean reserved = false;
        if (path != null && bytes.hasArray() && bytes.arrayOffset() == 0
                && Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            synchronized (lifecycle) { reserved = !closed && batch.reserve(size); }
        }
        if (!reserved) { access.synchronous(x, y, bytes); return; }
        LockReference reference = null;
        boolean submitted = false;
        var secured = new CompletableFuture<Void>();
        try {
            byte[] copy = Arrays.copyOf(bytes.array(), size);
            reference = access.reserve(x, y);
            var ownedReference = reference;
            owners.execute(() -> own(batch, path, copy, ownedReference, secured));
            submitted = true;
        } catch (RejectedExecutionException stopped) {
            // Never started: safe to use the original synchronous writer exactly once.
        } finally {
            if (!submitted) {
                try { if (reference != null) reference.close(); }
                finally { batch.release(size); }
            }
        }
        if (!submitted) { access.synchronous(x, y, bytes); return; }
        // A queued task is NOT ownership. Return only after the original lock + channel are held
        // and disk execution is admitted. Same-file dependencies still wait, as they must.
        boolean interrupted = false;
        try {
            while (true) {
                try { secured.get(); break; }
                catch (InterruptedException signal) { interrupted = true; }
                catch (ExecutionException failed) { throw new IOException("Private chunk handoff failed", failed.getCause()); }
            }
            if (interrupted) throw new InterruptedIOException("Interrupted after securing private chunk write");
        } finally { if (interrupted) Thread.currentThread().interrupt(); }
    }
    private void own(Batch batch, Path path, byte[] bytes, LockReference reference, CompletableFuture<Void> secured) {
        Lock lock = null;
        boolean locked = false, interrupted = false;
        try {
            lock = reference.writeLock(); lock.lock(); locked = true;
            // Lock acquisition and release stay on this SAME owner. Disk code never takes a game lock.
            try (FileChannel file = FileChannel.open(path, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                var written = new CompletableFuture<Void>();
                writer.execute(() -> {
                    try { sink.write(file, bytes); written.complete(null); }
                    catch (Throwable failure) { written.completeExceptionally(failure); }
                });
                secured.complete(null);
                while (true) {
                    try { written.get(); break; }
                    catch (InterruptedException signal) { interrupted = true; }
                    catch (ExecutionException failure) { throw failure.getCause(); }
                }
                // Close precedes unlock. A dequeued/completed disk task alone cannot finish the batch.
            }
        } catch (Throwable failure) {
            batch.fail(failure); secured.completeExceptionally(failure);
        } finally {
            try { if (locked) lock.unlock(); }
            catch (Throwable failure) { batch.fail(failure); secured.completeExceptionally(failure); }
            finally {
                try { reference.close(); }
                catch (Throwable failure) { batch.fail(failure); secured.completeExceptionally(failure); }
                finally { batch.release(bytes.length); }
            }
            if (interrupted) Thread.currentThread().interrupt();
        }
    }
    /** Stops admission, not accepted writes. Do not close the disk queue while owners may still submit to it. */
    @Override public void close() {
        synchronized (lifecycle) {
            if (closed) return;
            closed = true; owners.shutdown();
            Batch batch = active.get();
            if (batch == null || batch.pendingCount() == 0) writer.shutdown();
        }
    }
    boolean isIdle() { return active.get() == null; }
    void retire() throws Exception {
        if (!isIdle()) throw new IllegalStateException("Chunk writes still owned");
        close();
        if (!owners.awaitTermination(5, TimeUnit.SECONDS) || !writer.awaitTermination(5, TimeUnit.SECONDS))
            throw new IOException("Chunk executors did not retire");
    }
    private void released() {
        synchronized (lifecycle) {
            Batch batch = active.get();
            if (closed && (batch == null || batch.pendingCount() == 0)) writer.shutdown();
        }
    }
    final class Batch {
        final SaveProvider.Context context;
        final Path root;
        final long limit;
        final Consumer<Throwable> failure;
        private final AtomicReference<Throwable> firstFailure = new AtomicReference<>();
        volatile boolean capturing = true;
        private long retained;
        private int pending;
        Batch(SaveProvider.Context context, long limit, Consumer<Throwable> failure) {
            this.context = context; this.root = context.sourcePath().toAbsolutePath().normalize();
            this.limit = limit; this.failure = failure;
        }
        synchronized boolean reserve(int bytes) {
            if (bytes < 0 || bytes > limit - retained || pending >= MAXIMUM_PENDING) return false;
            retained += bytes; pending++; return true;
        }
        void release(int bytes) {
            synchronized (this) { retained -= bytes; pending--; notifyAll(); }
            released();
        }
        void fail(Throwable problem) {
            if (firstFailure.compareAndSet(null, problem)) {
                try { failure.accept(problem); }
                catch (Throwable reportingFailure) { if (reportingFailure != problem) problem.addSuppressed(reportingFailure); }
            }
        }
        synchronized int pendingCount() { return pending; }
        synchronized long retainedBytes() { return retained; }
        void seal() { capturing = false; }
        void await() throws IOException {
            if (Thread.currentThread() == context.gameThread()) throw new IllegalStateException("Completion must not join on game thread");
            if (capturing) throw new IllegalStateException("Capture must be sealed before completion" );
            boolean interrupted = Thread.interrupted();
            synchronized (this) {
                while (pending != 0) {
                    try { wait(); } catch (InterruptedException signal) { interrupted = true; }
                }
            }
            active.compareAndSet(this, null);
            if (interrupted) {
                Thread.currentThread().interrupt(); throw new InterruptedIOException("Interrupted after draining owned chunks");
            }
            if (firstFailure.get() != null) throw new IOException("Captured chunk write failed after cleanup", firstFailure.get());
        }
    }
}
