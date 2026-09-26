package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.Arrays;
import java.util.Objects;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.function.Consumer;

/** Detached write-back bytes only. Readers hold the game's original file lock; the writer never acquires it. */
final class DeferredChunkWrites implements FileWriteHooks.Handler, AutoCloseable {
    static final int MAXIMUM_PENDING = 128;
    @FunctionalInterface interface Sink { void write(FileChannel file, byte[] bytes) throws IOException; }
    private final Sink sink;
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private final ConcurrentHashMap<Path, PendingWrite> tails = new ConcurrentHashMap<>();
    private final ThreadPoolExecutor writer = new ThreadPoolExecutor(1, 1, 5, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(MAXIMUM_PENDING), runnable -> {
            Thread thread = new Thread(runnable, "PzTools-chunk-writer");
            thread.setDaemon(true); return thread;
        }, new ThreadPoolExecutor.AbortPolicy());

    DeferredChunkWrites() { this(DeferredChunkWrites::writeBytes); }
    DeferredChunkWrites(Sink sink) { this.sink = sink; writer.allowCoreThreadTimeOut(true); }
    static void writeBytes(FileChannel file, byte[] bytes) throws IOException {
        file.truncate(0); file.position(0);
        ByteBuffer buffer = ByteBuffer.wrap(bytes);
        while (buffer.hasRemaining()) file.write(buffer);
        // Same durability contract as vanilla SafeWrite: close, not a hardware-flush promise.
    }
    Batch begin(SaveProvider.Context context, long limit, Consumer<Throwable> failure) {
        context.requireGameThread();
        if (limit < 1) throw new IllegalArgumentException("A positive memory budget is required");
        var batch = new Batch(context, limit, failure);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Chunk writes still owned");
        return batch;
    }
    @Override public boolean tryDefer(File file, ByteBuffer buffer) throws IOException {
        Batch batch = active.get();
        if (batch == null && tails.isEmpty()) return false;
        Path path = file.toPath().toAbsolutePath().normalize();
        if (batch != null && batch.capturing && Thread.currentThread() == batch.context.gameThread()
                && path.startsWith(batch.root) && buffer.hasArray() && buffer.arrayOffset() == 0
                && batch.reserve(buffer.position())) {
            int length = buffer.position();
            FileChannel channel = null;
            PendingWrite pending = null, previous = null;
            boolean published = false, accepted = false;
            try {
                // First creation remains synchronous: loaders can check existence before SafeRead.
                var before = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                if (before.isRegularFile()) {
                    channel = FileChannel.open(path, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                    var after = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                    if (!after.isRegularFile() || !Objects.equals(before.fileKey(), after.fileKey()))
                        throw new IOException("Chunk file changed while preparing its write");
                    byte[] owned = Arrays.copyOf(buffer.array(), length);
                    pending = new PendingWrite(batch, owned, PinnedFileIdentity.key(channel));
                    previous = tails.put(path, pending); published = true;
                    FileChannel output = channel;
                    PendingWrite submitted = pending;
                    writer.execute(() -> write(path, submitted, output, owned));
                    accepted = true;
                    batch.deferred.incrementAndGet();
                    return true;
                }
            } catch (NoSuchFileException disappeared) {
                // Preserve original creation after older writes to this path complete.
            } catch (RejectedExecutionException unavailable) {
                // Exhaustion uses ordered original I/O, never a dropped chunk.
            } catch (IOException | RuntimeException | Error failure) {
                batch.failure.accept(failure); throw failure;
            } finally {
                if (!accepted) {
                    if (published) {
                        if (previous == null) tails.remove(path, pending);
                        else {
                            tails.replace(path, pending, previous);
                            if (previous.completion.isDone()) tails.remove(path, previous);
                        }
                    }
                    try { if (channel != null) channel.close(); }
                    catch (IOException closeFailure) { batch.failure.accept(closeFailure); throw closeFailure; }
                    finally { if (pending != null) pending.release(); else batch.release(length); }
                }
            }
        }
        awaitPath(path, false);
        if (batch != null && batch.capturing && Thread.currentThread() == batch.context.gameThread())
            batch.synchronous.incrementAndGet();
        return false;
    }
    private void write(Path path, PendingWrite pending, FileChannel channel, byte[] owned) {
        Throwable problem = null;
        try (channel) { sink.write(channel, owned); }
        catch (Throwable failure) { problem = failure; pending.batch.failure.accept(failure); }
        finally {
            if (problem == null) pending.completion.complete(null); else pending.completion.completeExceptionally(problem);
            tails.remove(path, pending);
            // Includes a concurrent read's copy. The batch cannot finish while bytes/handles are still in use.
            pending.release();
        }
    }
    @Override public ByteBuffer tryRead(File file, ByteBuffer destination) throws IOException {
        if (tails.isEmpty()) return null;
        Path path = file.toPath().toAbsolutePath().normalize();
        PendingWrite pending = tails.get(path);
        if (pending == null || pending.fileKey == null) return null;
        if (!PinnedFileIdentity.matches(path, pending.fileKey)) return null;
        return pending.copy(destination);
    }
    private void awaitPath(Path path, boolean reading) throws IOException {
        PendingWrite previous = tails.get(path);
        if (previous == null) return;
        try { previous.completion.join(); }
        catch (CompletionException failure) {
            if (reading) throw new IOException("Earlier chunk write failed", failure.getCause());
        }
    }
    @Override public void beforeRead(File file) throws IOException {
        if (!tails.isEmpty()) awaitPath(file.toPath().toAbsolutePath().normalize(), true);
    }
    @Override public void beforeSynchronousSave() {
        Batch batch = active.get();
        if (batch != null && batch.capturing && Thread.currentThread() == batch.context.gameThread()) return;
        for (var pending : tails.values().toArray(PendingWrite[]::new)) {
            try { pending.completion.join(); } catch (CompletionException alreadyReported) { }
        }
    }
    @Override public void close() { writer.shutdown(); }

    private final class PendingWrite {
        final Batch batch;
        final Object fileKey;
        final CompletableFuture<Void> completion = new CompletableFuture<>();
        private byte[] bytes;
        PendingWrite(Batch batch, byte[] bytes, Object fileKey) { this.batch = batch; this.bytes = bytes; this.fileKey = fileKey; }
        synchronized ByteBuffer copy(ByteBuffer destination) throws IOException {
            if (bytes == null) return null;
            if (completion.isCompletedExceptionally()) {
                try { completion.join(); } catch (CompletionException failure) { throw new IOException("Pending chunk write failed", failure.getCause()); }
            }
            if (destination == null || destination.isReadOnly() || !destination.hasArray()
                    || destination.arrayOffset() != 0 || destination.capacity() < bytes.length)
                destination = ByteBuffer.allocate(bytes.length);
            destination.clear(); destination.put(bytes); destination.flip();
            batch.readThrough.incrementAndGet();
            return destination; // Never exposes our retained array to game mutation.
        }
        synchronized void release() {
            if (bytes == null) return;
            int size = bytes.length; bytes = null;
            batch.release(size);
        }
    }
    final class Batch {
        final SaveProvider.Context context;
        final Path root;
        final long limit;
        final Consumer<Throwable> failure;
        final AtomicInteger deferred = new AtomicInteger(), synchronous = new AtomicInteger(), readThrough = new AtomicInteger();
        volatile boolean capturing = true;
        private long retained, peak;
        private int pending;
        Batch(SaveProvider.Context context, long limit, Consumer<Throwable> failure) {
            this.context = context; this.root = context.sourcePath().toAbsolutePath().normalize();
            this.limit = limit; this.failure = failure;
        }
        synchronized boolean reserve(int bytes) {
            if (bytes < 0 || bytes > limit - retained || pending >= MAXIMUM_PENDING) return false;
            retained += bytes; peak = Math.max(peak, retained); pending++; return true;
        }
        synchronized void release(int bytes) { retained -= bytes; pending--; notifyAll(); }
        synchronized long retainedBytes() { return retained; }
        synchronized long peakBytes() { return peak; }
        void seal() { capturing = false; }
        void await() throws InterruptedIOException {
            if (Thread.currentThread() == context.gameThread())
                throw new IllegalStateException("Cannot await chunk disk writes on the game thread");
            boolean interrupted = false;
            synchronized (this) {
                while (pending != 0) {
                    try { wait(); } catch (InterruptedException cancellation) { interrupted = true; }
                }
            }
            active.compareAndSet(this, null);
            if (interrupted) {
                Thread.currentThread().interrupt();
                throw new InterruptedIOException("Interrupted after draining owned chunk writes");
            }
        }
    }
}