package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.Arrays;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.function.Consumer;

/** Detached writes only. No world lookup, game locks, reflection or live chunk objects on the writer. */
final class DeferredChunkWrites implements FileWriteHooks.Handler, AutoCloseable {
    static final int MAXIMUM_PENDING = 128;
    @FunctionalInterface interface Sink { void write(FileChannel file, byte[] bytes) throws IOException; }
    private final Sink sink;
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private final ConcurrentHashMap<Path, CompletableFuture<Void>> tails = new ConcurrentHashMap<>();
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
            CompletableFuture<Void> completion = new CompletableFuture<>();
            CompletableFuture<Void> previous = null;
            boolean published = false, accepted = false;
            try {
                // First creation remains synchronous: a loader can check existence before SafeRead.
                BasicFileAttributes attributes = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                if (attributes.isRegularFile()) {
                    // Pin the existing file without truncation. No game/world path lookup in the writer.
                    channel = FileChannel.open(path, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                    byte[] owned = Arrays.copyOf(buffer.array(), length);
                    FileChannel output = channel;
                    previous = tails.put(path, completion); published = true;
                    writer.execute(() -> write(batch, path, completion, output, owned));
                    accepted = true;
                    batch.deferred.incrementAndGet();
                    return true;
                }
            } catch (NoSuchFileException disappeared) {
                // Preserve original creation, after older writes to this path have completed.
            } catch (RejectedExecutionException unavailable) {
                // Exhaustion uses ordered original I/O, never a dropped chunk.
            } catch (IOException | RuntimeException | Error failure) {
                batch.failure.accept(failure); throw failure;
            } finally {
                if (!accepted) {
                    if (published) {
                        if (previous == null) tails.remove(path, completion);
                        else {
                            tails.replace(path, completion, previous);
                            if (previous.isDone()) tails.remove(path, previous);
                        }
                    }
                    try { if (channel != null) channel.close(); }
                    catch (IOException closeFailure) { batch.failure.accept(closeFailure); throw closeFailure; }
                    finally { batch.release(length); }
                }
            }
        }
        awaitPath(path, false);
        if (batch != null && batch.capturing && Thread.currentThread() == batch.context.gameThread())
            batch.synchronous.incrementAndGet();
        return false;
    }
    private void write(Batch batch, Path path, CompletableFuture<Void> completion, FileChannel channel, byte[] owned) {
        Throwable problem = null;
        try (channel) { sink.write(channel, owned); }
        catch (Throwable failure) { problem = failure; batch.failure.accept(failure); }
        finally {
            batch.release(owned.length);
            if (problem == null) completion.complete(null); else completion.completeExceptionally(problem);
            tails.remove(path, completion);
        }
    }
    private void awaitPath(Path path, boolean reading) throws IOException {
        CompletableFuture<Void> previous = tails.get(path);
        if (previous == null) return;
        try { previous.join(); }
        catch (CompletionException failure) {
            // The failed batch already recorded the error. Do not suppress a newer ordinary write.
            if (reading) throw new IOException("Earlier chunk write failed", failure.getCause());
        }
    }
    @Override public void beforeRead(File file) throws IOException {
        if (!tails.isEmpty()) awaitPath(file.toPath().toAbsolutePath().normalize(), true);
    }
    @Override public void beforeSynchronousSave() {
        Batch batch = active.get();
        if (batch != null && batch.capturing && Thread.currentThread() == batch.context.gameThread()) return;
        // Ordinary/exit saves cannot be overtaken by older detached writes.
        // Previous failures belong to that batch; allow the user's new ordinary save to proceed.
        for (var pending : tails.values().toArray(CompletableFuture[]::new)) {
            try { pending.join(); } catch (CompletionException alreadyReported) { }
        }
    }
    @Override public void close() { writer.shutdown(); }

    final class Batch {
        final SaveProvider.Context context;
        final Path root;
        final long limit;
        final Consumer<Throwable> failure;
        final AtomicInteger deferred = new AtomicInteger(), synchronous = new AtomicInteger();
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