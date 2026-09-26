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

/** Private-call-only I/O. Vanilla readers/writers use the SAME game lock; no public read/write hooks are needed. */
final class OwnedChunkWrites implements AutoCloseable {
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
    // One writer overlaps current disk I/O with next-chunk serialization; never multiplies disk pressure.
    private final ThreadPoolExecutor writer = new ThreadPoolExecutor(1, 1, 5, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(1), runnable -> {
            Thread thread = new Thread(runnable, "PzTools-owned-chunk-writer"); thread.setDaemon(true); return thread;
        }, new ThreadPoolExecutor.AbortPolicy());
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
        Batch batch = new Batch(context, limit, failure);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Private chunk writes are still owned");
        return batch;
    }
    public void write(int x, int y, ByteBuffer bytes) throws Exception {
        Batch batch = active.get();
        if (batch == null || !batch.capturing) throw new IllegalStateException("No private save capture");
        batch.context.requireGameThread();
        File file = access.destination(x, y);
        Path path = file == null ? null : file.toPath().toAbsolutePath().normalize();
        if (path != null && !path.startsWith(batch.context.sourcePath().toAbsolutePath().normalize()))
            throw new IOException("Chunk destination left the selected world" );
        int size = bytes.position();
        // First-file publication stays synchronous. No placeholders or hidden changes to vanilla existence checks.
        if (path == null || !path.startsWith(batch.context.sourcePath().toAbsolutePath().normalize())
                || !bytes.hasArray() || bytes.arrayOffset() != 0
                || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || !batch.reserve(size)) {
            access.synchronous(x, y, bytes); return;
        }
        LockReference reference = null;
        boolean submitted = false;
        var secured = new CompletableFuture<Void>();
        try {
            byte[] copy = Arrays.copyOf(bytes.array(), size);
            reference = access.reserve(x, y);
            var ownedReference = reference;
            writer.execute(() -> commit(batch, path, copy, ownedReference, secured));
            submitted = true;
        } catch (RejectedExecutionException stopped) {
            // Not accepted: no background write can occur. Ordered vanilla fallback is safe.
        } finally {
            if (!submitted) {
                try { if (reference != null) reference.close(); }
                finally { batch.release(size); }
            }
        }
        if (!submitted) { access.synchronous(x, y, bytes); return; }
        // A task in a queue is NOT lock ownership. Do not let an unmodified vanilla writer overtake it.
        // This short handoff can wait on contention/previous I/O; it is not advertised as zero-blocking.
        boolean interrupted = false;
        try {
            while (true) {
                try { secured.get(); break; }
                catch (InterruptedException signal) { interrupted = true; }
                catch (ExecutionException failed) { throw new IOException("Private chunk lock/open failed", failed.getCause()); }
            }
            if (interrupted) throw new InterruptedIOException("Interrupted after securing private chunk write");
        } finally { if (interrupted) Thread.currentThread().interrupt(); }
    }
    private void commit(Batch batch, Path path, byte[] bytes, LockReference reference, CompletableFuture<Void> secured) {
        Lock lock = null;
        boolean locked = false;
        try {
            lock = reference.writeLock(); lock.lock(); locked = true;
            // Open without truncation before publishing the handoff; later renaming cannot redirect this write.
            try (FileChannel file = FileChannel.open(path, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                secured.complete(null);
                sink.write(file, bytes);
            }
        } catch (Throwable failure) {
            batch.failure.accept(failure); secured.completeExceptionally(failure);
        } finally {
            try { if (locked) lock.unlock(); }
            catch (Throwable failure) { batch.failure.accept(failure); secured.completeExceptionally(failure); }
            finally {
                try { reference.close(); }
                catch (Throwable failure) { batch.failure.accept(failure); secured.completeExceptionally(failure); }
                finally { batch.release(bytes.length); }
            }
        }
    }
    @Override public void close() { writer.shutdown(); }
    final class Batch {
        final SaveProvider.Context context;
        final long limit;
        final Consumer<Throwable> failure;
        volatile boolean capturing = true;
        private long retained;
        private int pending;
        Batch(SaveProvider.Context context, long limit, Consumer<Throwable> failure) {
            this.context = context; this.limit = limit; this.failure = failure;
        }
        synchronized boolean reserve(int bytes) {
            if (bytes < 0 || bytes > limit - retained || pending >= 2) return false;
            retained += bytes; pending++; return true;
        }
        synchronized void release(int bytes) { retained -= bytes; pending--; notifyAll(); }
        synchronized long retainedBytes() { return retained; }
        void seal() { capturing = false; }
        void await() throws InterruptedIOException {
            if (Thread.currentThread() == context.gameThread()) throw new IllegalStateException("Completion must not join on game thread");
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
        }
    }
}
