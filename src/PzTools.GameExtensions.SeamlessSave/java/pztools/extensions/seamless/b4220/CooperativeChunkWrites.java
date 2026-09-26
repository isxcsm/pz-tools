package pztools.extensions.seamless.b4220;

import pztools.extensions.api.SaveProvider;
import java.io.*;
import java.nio.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.Lock;
import java.util.function.Consumer;

/** Speculative file baselines avoid waiting for lock/open handoff on the game thread.
 * Before writing, the original file lock and exact baseline bytes are checked again.
 * A newer ordinary write is never overwritten by an older captured input.
 */
final class CooperativeChunkWrites implements AutoCloseable {
    private static final int CAPACITY = 32;
    private final OwnedChunkWrites.Access access;
    private final ThreadPoolExecutor worker = new ThreadPoolExecutor(1, 1, 5, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(CAPACITY * 3), Thread.ofPlatform().daemon(true)
            .name("PzTools-cooperative-chunk-io").inheritInheritableThreadLocals(false).factory());
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private volatile boolean closed;
    private Ticket current;
    private final ByteBuffer hashBuffer = ByteBuffer.allocate(32 * 1024); // Confined to the single I/O worker.
    CooperativeChunkWrites(OwnedChunkWrites.Access access) {
        this.access = access; worker.allowCoreThreadTimeOut(true);
    }
    Batch begin(SaveProvider.Context context, long budget, Consumer<Throwable> report) {
        context.requireGameThread();
        if (closed) throw new IllegalStateException("Chunk writer retired");
        var batch = new Batch(context, budget, report);
        if (!active.compareAndSet(null, batch)) throw new IllegalStateException("Chunk inputs still owned");
        return batch;
    }
    /** The private serializer calls this while its current ticket is bound, never for an ordinary save. */
    public void write(int x, int y, ByteBuffer bytes) throws Exception {
        Ticket ticket = current;
        if (ticket == null || ticket.x != x || ticket.y != y || ticket.submitted)
            throw new IllegalStateException("Unexpected private chunk output");
        ticket.batch.context.requireGameThread();
        int size = bytes.position();
        if (!bytes.hasArray() || size < 0 || size > bytes.capacity()) throw new IOException("Unsupported chunk buffer");
        ticket.submitted = true;
        boolean queued = false;
        try {
            if (ticket.fresh) {
                // New files keep immediate visibility, but do not wait on another worker.
                access.synchronous(x, y, bytes);
                worker.execute(ticket::finish); queued = true; return;
            }
            synchronized (ticket.batch) {
                if (size > ticket.batch.budget - ticket.batch.retained)
                    throw new IOException("Chunk input budget exhausted");
                ticket.batch.retained += size; ticket.size = size;
            }
            ticket.data = Arrays.copyOfRange(bytes.array(), bytes.arrayOffset(), bytes.arrayOffset() + size);
            worker.execute(ticket::store); queued = true;
        } catch (Throwable failure) {
            ticket.fail(failure);
            if (failure instanceof Exception exception) throw exception;
            throw (Error)failure;
        } finally {
            // Even allocation/budget/submission failure must release a prepared channel and counted lock.
            if (!queued) worker.execute(ticket::finish);
        }
    }

    void bind(Ticket ticket) { if (current != null) throw new IllegalStateException("Nested private output"); current = ticket; }
    void unbind(Ticket ticket) {
        current = null;
        if (!ticket.submitted && !ticket.finished) worker.execute(ticket::finish);
    }
    boolean isIdle() { return active.get() == null; }
    @Override public void close() { closed = true; if (isIdle()) worker.shutdown(); }
    void retire() throws Exception {
        if (!isIdle()) throw new IllegalStateException("Chunk work still active");
        close(); if (!worker.awaitTermination(5, TimeUnit.SECONDS)) throw new IOException("Chunk writer still alive");
    }
    final class Batch {
        final SaveProvider.Context context;
        final long budget;
        final Consumer<Throwable> report;
        final Set<Ticket> pending = new HashSet<>();
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        long retained;
        boolean sealed;
        Batch(SaveProvider.Context context, long budget, Consumer<Throwable> report) {
            this.context = context; this.budget = budget; this.report = report;
        }
        Ticket prepare(int x, int y) throws Exception {
            context.requireGameThread();
            synchronized (this) { if (sealed || closed || pending.size() >= CAPACITY) return null; }
            File destination = access.destination(x, y);
            if (destination == null) throw new IOException("Game saving was disabled");
            Path path = destination.toPath().toAbsolutePath().normalize();
            if (!path.startsWith(context.sourcePath().toAbsolutePath().normalize())) throw new IOException("Chunk left the selected world");
            var ticket = new Ticket(this, path, x, y, access.reserve(x, y));
            synchronized (this) { pending.add(ticket); }
            try { worker.execute(ticket::prepare); }
            catch (RuntimeException failure) { ticket.fail(failure); ticket.finish(); throw failure; }
            return ticket;
        }
        synchronized long retainedBytes() { return retained; }
        synchronized boolean settled() { return pending.isEmpty(); }
        void fail(Throwable problem) {
            if (failure.compareAndSet(null, problem)) report.accept(problem);
        }
        void seal() {
            synchronized (this) {
                sealed = true;
                for (var ticket : List.copyOf(pending)) if (!ticket.submitted) ticket.cancel();
            }
        }
        void await() throws IOException {
            if (Thread.currentThread() == context.gameThread()) throw new IllegalStateException("Cannot join I/O on the game thread");
            boolean interrupted = Thread.interrupted();
            synchronized (this) {
                if (!sealed) throw new IllegalStateException("Capture not sealed");
                while (!pending.isEmpty()) try { wait(); } catch (InterruptedException signal) { interrupted = true; }
            }
            active.compareAndSet(this, null);
            if (closed) worker.shutdown();
            if (interrupted) Thread.currentThread().interrupt();
            if (failure.get() != null) throw new IOException("Private chunk I/O failed", failure.get());
            if (interrupted) throw new InterruptedIOException("Interrupted after draining private writes");
        }
    }
    final class Ticket {
        final Batch batch;
        final Path path;
        final int x, y;
        final OwnedChunkWrites.LockReference reference;
        final AtomicBoolean released = new AtomicBoolean();
        volatile boolean ready, finished, fresh, conflict, submitted, cancelled;
        volatile Throwable failure;
        FileChannel channel;
        byte[] baseline, data;
        int size;
        Ticket(Batch batch, Path path, int x, int y, OwnedChunkWrites.LockReference reference) {
            this.batch = batch; this.path = path; this.x = x; this.y = y; this.reference = reference;
        }
        void cancel() { cancelled = true; worker.execute(this::finish); }
        void prepare() {
            Lock lock = null; boolean held = false;
            try {
                if (cancelled) { finish(); return; }
                lock = reference.writeLock(); lock.lock(); held = true;
                if (!batch.context.worldValid().get()) throw new IOException("World ended before file preparation");
                try { channel = FileChannel.open(path, StandardOpenOption.READ, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS); }
                catch (NoSuchFileException absent) { fresh = true; }
                if (!fresh) baseline = hash(channel);
                ready = true;
            } catch (Throwable problem) { fail(problem); }
            finally { if (held) lock.unlock(); if (failure != null) finish(); }
        }
        void store() {
            Lock lock = null; boolean held = false;
            try {
                if (cancelled) return;
                lock = reference.writeLock(); lock.lock(); held = true;
                if (!batch.context.worldValid().get()) throw new IOException("World ended before chunk write");
                if (!Arrays.equals(baseline, hash(channel)) || !Arrays.equals(baseline, hashPath(path))) {
                    conflict = true; return; // A later vanilla save wins. The game thread must recapture, not replay bytes.
                }
                OwnedChunkWrites.writeBytes(channel, data);
                if (!Arrays.equals(MessageDigest.getInstance("SHA-256").digest(data), hashPath(path)))
                    throw new IOException("Chunk path was replaced during writing");
            } catch (Throwable problem) { fail(problem); }
            finally {
                try { if (channel != null) { channel.close(); channel = null; } }
                catch (Throwable problem) { fail(problem); }
                finally { if (held) lock.unlock(); finish(); }
            }
        }
        void fail(Throwable problem) {
            if (failure == null) failure = problem;
            try { batch.fail(problem); } catch (Throwable reporting) { if (reporting != problem) problem.addSuppressed(reporting); }
        }
        void finish() {
            if (!released.compareAndSet(false, true)) return;
            try { if (channel != null) channel.close(); }
            catch (Throwable problem) { fail(problem); }
            finally {
                try { reference.close(); } catch (Throwable problem) { fail(problem); }
                data = null; baseline = null;
                synchronized (batch) {
                    batch.retained -= size; batch.pending.remove(this); finished = true; batch.notifyAll();
                }
            }
        }
    }
    private byte[] hashPath(Path path) throws Exception {
        try (var channel = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            return hash(channel);
        } catch (NoSuchFileException replaced) { return null; }
    }
    private byte[] hash(FileChannel file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        ByteBuffer buffer = hashBuffer; buffer.clear();
        file.position(0);
        while (file.read(buffer) != -1) {
            buffer.flip(); digest.update(buffer); buffer.clear();
        }
        return digest.digest();
    }
}
