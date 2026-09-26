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
    private static final int PREPARE_OPEN = 0, PREPARE_HASH = 1, STORE_PINNED_HASH = 2,
        STORE_PATH_BEFORE = 3, STORE_WRITE = 4, STORE_OUTPUT_HASH = 5, STORE_PATH_AFTER = 6,
        CHANNEL_CLOSE = 7, FRESH_WRITE = 8;
    private final OwnedChunkWrites.Access access;
    // Every operation for one path stays FIFO on one lane, including cancelled/replaced tickets.
    // The shared batch still bounds BOTH lanes to 32 tickets and one retained-byte budget.
    private final Lane[] lanes = { new Lane(0), new Lane(1) };
    private final AtomicReference<Batch> active = new AtomicReference<>();
    private volatile boolean closed;
    private Ticket current;
    CooperativeChunkWrites(OwnedChunkWrites.Access access) {
        this.access = access;
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
                long started = System.nanoTime();
                try { access.synchronous(x, y, bytes); }
                finally { ticket.batch.recordDetail(FRESH_WRITE, System.nanoTime() - started); }
                ticket.queueFinish(); queued = true; return;
            }
            synchronized (ticket.batch) {
                if (size > ticket.batch.budget - ticket.batch.retained)
                    throw new IOException("Chunk input budget exhausted");
                ticket.batch.retained += size; ticket.size = size;
            }
            ticket.data = Arrays.copyOfRange(bytes.array(), bytes.arrayOffset(), bytes.arrayOffset() + size);
            ticket.storeQueuedAt = System.nanoTime();
            ticket.lane.worker.execute(ticket::store); queued = true;
        } catch (Throwable failure) {
            ticket.fail(failure);
            if (failure instanceof Exception exception) throw exception;
            throw (Error)failure;
        } finally {
            // Even allocation/budget/submission failure must release a prepared channel and counted lock.
            if (!queued) ticket.queueFinish();
        }
    }

    void bind(Ticket ticket) { if (current != null) throw new IllegalStateException("Nested private output"); current = ticket; }
    void unbind(Ticket ticket) {
        current = null;
        if (!ticket.submitted && !ticket.finished) ticket.queueFinish();
    }
    boolean isIdle() { return active.get() == null; }
    private void shutdown() { for (var lane : lanes) lane.worker.shutdown(); }
    @Override public void close() { closed = true; if (isIdle()) shutdown(); }
    void retire() throws Exception {
        if (!isIdle()) throw new IllegalStateException("Chunk work still active");
        close();
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        for (var lane : lanes)
            if (!lane.worker.awaitTermination(Math.max(0, until - System.nanoTime()), TimeUnit.NANOSECONDS))
                throw new IOException("Chunk writer still alive");
    }
    final class Batch {
        final SaveProvider.Context context;
        final long budget;
        final Consumer<Throwable> report;
        final Set<Ticket> pending = new HashSet<>();
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        long retained;
        long queueNanos, prepareNanos, writeNanos, lockNanos;
        final long[] detailNanos = new long[9];
        int preparations, stores;
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
            try { ticket.lane.worker.execute(ticket::prepare); }
            catch (RuntimeException failure) { ticket.fail(failure); ticket.finish(); throw failure; }
            return ticket;
        }
        synchronized long retainedBytes() { return retained; }
        synchronized String diagnostics() {
            var detail = new StringJoiner(",");
            for (long elapsed : detailNanos) detail.add(Long.toString(elapsed / 1000));
            return "chunkIoStatsV1=" + preparations + "," + stores + "," + queueNanos / 1000 + ","
                + prepareNanos / 1000 + "," + writeNanos / 1000 + "," + lockNanos / 1000
                + "; chunkIoDetailStatsV1=" + detail;
        }
        // Path verification includes its open/read/hash/close. These are service-time subsets,
        // not extra wall time; services on the two lanes can overlap with each other.
        synchronized void recordDetail(int phase, long elapsed) { detailNanos[phase] += elapsed; }
        synchronized void recordIo(boolean prepare, long queued, long elapsed, long locked) {
            queueNanos += queued; lockNanos += locked;
            if (prepare) { preparations++; prepareNanos += elapsed; }
            else { stores++; writeNanos += elapsed; }
        }
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
            if (closed) shutdown();
            if (interrupted) Thread.currentThread().interrupt();
            if (failure.get() != null) throw new IOException("Private chunk I/O failed", failure.get());
            if (interrupted) throw new InterruptedIOException("Interrupted after draining private writes");
        }
    }
    final class Ticket {
        final Batch batch;
        final Path path;
        final Lane lane;
        final int x, y;
        final OwnedChunkWrites.LockReference reference;
        final AtomicBoolean released = new AtomicBoolean();
        final AtomicBoolean finishQueued = new AtomicBoolean();
        volatile boolean ready, finished, fresh, conflict, submitted, cancelled;
        volatile Throwable failure;
        FileChannel channel;
        byte[] baseline, data;
        int size;
        final long prepareQueuedAt = System.nanoTime();
        long storeQueuedAt;
        Ticket(Batch batch, Path path, int x, int y, OwnedChunkWrites.LockReference reference) {
            this.batch = batch; this.path = path; this.x = x; this.y = y; this.reference = reference;
            lane = lanes[Math.floorMod(path.hashCode(), lanes.length)];
        }
        void queueFinish() { if (finishQueued.compareAndSet(false, true)) lane.worker.execute(this::finish); }
        void cancel() { cancelled = true; queueFinish(); }
        void prepare() {
            Lock lock = null; boolean held = false;
            long started = System.nanoTime(), lockWait = 0;
            try {
                if (cancelled) return;
                lock = reference.writeLock();
                long lockStarted = System.nanoTime(); lock.lock(); held = true;
                lockWait = System.nanoTime() - lockStarted;
                if (!batch.context.worldValid().get()) throw new IOException("World ended before file preparation");
                long phase = System.nanoTime();
                try { channel = FileChannel.open(path, StandardOpenOption.READ, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS); }
                catch (NoSuchFileException absent) { fresh = true; }
                finally { batch.recordDetail(PREPARE_OPEN, System.nanoTime() - phase); }
                if (!fresh) baseline = hash(channel, PREPARE_HASH);
                ready = true;
            } catch (Throwable problem) { fail(problem); }
            finally {
                if (held) lock.unlock();
                batch.recordIo(true, Math.max(0, started - prepareQueuedAt), System.nanoTime() - started, lockWait);
                if (failure != null || cancelled) finish();
            }
        }
        void store() {
            Lock lock = null; boolean held = false;
            long started = System.nanoTime(), lockWait = 0;
            try {
                if (cancelled) return;
                lock = reference.writeLock();
                long lockStarted = System.nanoTime(); lock.lock(); held = true;
                lockWait = System.nanoTime() - lockStarted;
                if (!batch.context.worldValid().get()) throw new IOException("World ended before chunk write");
                if (!Arrays.equals(baseline, hash(channel, STORE_PINNED_HASH))
                        || !Arrays.equals(baseline, hashPath(STORE_PATH_BEFORE))) {
                    conflict = true; return; // A later vanilla save wins. The game thread must recapture, not replay bytes.
                }
                long phase = System.nanoTime();
                try { OwnedChunkWrites.writeBytes(channel, data); }
                finally { batch.recordDetail(STORE_WRITE, System.nanoTime() - phase); }
                byte[] outputHash;
                phase = System.nanoTime();
                try { lane.digest.reset(); outputHash = lane.digest.digest(data); }
                finally { batch.recordDetail(STORE_OUTPUT_HASH, System.nanoTime() - phase); }
                if (!Arrays.equals(outputHash, hashPath(STORE_PATH_AFTER)))
                    throw new IOException("Chunk path was replaced during writing");
            } catch (Throwable problem) { fail(problem); }
            finally {
                try { closeChannel(); }
                catch (Throwable problem) { fail(problem); }
                finally {
                    if (held) lock.unlock();
                    batch.recordIo(false, Math.max(0, started - storeQueuedAt), System.nanoTime() - started, lockWait);
                    finish();
                }
            }
        }
        void fail(Throwable problem) {
            if (failure == null) failure = problem;
            try { batch.fail(problem); } catch (Throwable reporting) { if (reporting != problem) problem.addSuppressed(reporting); }
        }
        void finish() {
            if (!released.compareAndSet(false, true)) return;
            try { closeChannel(); }
            catch (Throwable problem) { fail(problem); }
            finally {
                try { reference.close(); } catch (Throwable problem) { fail(problem); }
                data = null; baseline = null;
                synchronized (batch) {
                    batch.retained -= size; batch.pending.remove(this); finished = true; batch.notifyAll();
                }
            }
        }
        private void closeChannel() throws IOException {
            if (channel == null) return;
            long started = System.nanoTime();
            try { channel.close(); }
            finally { channel = null; batch.recordDetail(CHANNEL_CLOSE, System.nanoTime() - started); }
        }
        private byte[] hash(FileChannel file, int phase) throws Exception {
            long started = System.nanoTime();
            try { return lane.hash(file); }
            finally { batch.recordDetail(phase, System.nanoTime() - started); }
        }
        private byte[] hashPath(int phase) throws Exception {
            long started = System.nanoTime();
            try (var file = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
                return lane.hash(file);
            } catch (NoSuchFileException replaced) { return null; }
            finally { batch.recordDetail(phase, System.nanoTime() - started); }
        }
    }
    private static final class Lane {
        final ThreadPoolExecutor worker;
        // No game or other-lane access: the buffer and digest are reused only by this worker.
        final ByteBuffer hashBuffer = ByteBuffer.allocate(32 * 1024);
        final MessageDigest digest;
        Lane(int index) {
            try { digest = MessageDigest.getInstance("SHA-256"); }
            catch (NoSuchAlgorithmException failure) { throw new IllegalStateException("SHA-256 unavailable", failure); }
            worker = new ThreadPoolExecutor(1, 1, 5, TimeUnit.SECONDS,
                new ArrayBlockingQueue<>(CAPACITY * 3), Thread.ofPlatform().daemon(true)
                    .name("PzTools-cooperative-chunk-io-" + index).inheritInheritableThreadLocals(false).factory());
            worker.allowCoreThreadTimeOut(true);
        }
        byte[] hash(FileChannel file) throws IOException {
            digest.reset(); hashBuffer.clear(); file.position(0);
            while (file.read(hashBuffer) != -1) {
                hashBuffer.flip(); digest.update(hashBuffer); hashBuffer.clear();
            }
            return digest.digest();
        }
    }
}
