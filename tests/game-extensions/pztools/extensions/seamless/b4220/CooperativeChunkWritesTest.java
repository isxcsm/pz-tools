package pztools.extensions.seamless.b4220;

import pztools.extensions.api.SaveProvider;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.*;
import java.util.function.BooleanSupplier;

/** Real temporary files, deterministic lock gates, no installed game or user save access. */
public final class CooperativeChunkWritesTest {
    public static void main(String[] args) throws Exception { run(); }
    public static void run() throws Exception {
        independentPathsProgressTogether();
        samePathKeepsFifo();
        cancellationKeepsOwnership();
        newerVanillaWriteWins();
        freshPublicationStaysSynchronous();
        worldExitDrainsBothLanes();
        boundsRemainGlobal();
        System.out.println("PASS: two path-affine I/O lanes, same-path FIFO, cancellation/ownership, vanilla conflicts, world exit, global bounds and cost diagnostics");
    }

    private static void independentPathsProgressTogether() throws Exception {
        try (var f = new Fixture()) {
            int a = f.firstPath(0), b = f.firstPath(1);
            Gate prepareA = f.lock(a).gate(1), prepareB = f.lock(b).gate(1);
            var batch = f.begin(64);
            var first = batch.prepare(a, 0); prepareA.awaitEntered();
            var second = batch.prepare(b, 0); prepareB.awaitEntered();
            check(f.references.get() == 2 && !first.ready && !second.ready,
                "Two independent preparations were not simultaneously admitted");
            prepareA.release(); prepareB.release(); ready(first); ready(second);
            Gate storeA = f.lock(a).gate(2), storeB = f.lock(b).gate(2);
            ByteBuffer inputA = bytes(41), inputB = bytes(42);
            f.submit(first, inputA); storeA.awaitEntered();
            f.submit(second, inputB); storeB.awaitEntered();
            check(batch.retainedBytes() == 8, "Both lanes did not share retained-byte accounting");
            // The disk owners may only see the detached copy, not subsequent game-buffer reuse.
            inputA.putInt(0, -1); inputB.putInt(0, -1);
            storeA.release(); storeB.release();
            f.finish(false);
            check(f.read(a) == 41 && f.read(b) == 42, "Concurrent hashes or detached inputs were corrupted");
            check(f.threads.size() == 2, "More/fewer than two I/O workers processed independent paths");
            long[] detail = field(batch.diagnostics(), "chunkIoDetailStatsV1");
            check(detail.length == 9, "I/O detail diagnostics changed shape");
            for (long value : detail) check(value >= 0, "Negative I/O phase timing");
            check(field(batch.diagnostics(), "chunkIoStatsV1")[0] == 2,
                "Existing I/O aggregate counter was not preserved");
            check(detail[0] + detail[1] > 0 && detail[2] + detail[3] > 0
                && detail[4] + detail[5] + detail[6] > 0, "Successful I/O phases were not measured");
        }
    }

    private static void samePathKeepsFifo() throws Exception {
        try (var f = new Fixture()) {
            int x = f.firstPath(0), alias = 1000;
            f.paths.put(alias, f.path(x).getParent().resolve("unused/../" + f.path(x).getFileName()));
            var batch = f.begin(64);
            var first = batch.prepare(x, 0); ready(first);
            Gate store = f.lock(x).gate(2);
            f.submit(first, bytes(11)); store.awaitEntered();
            // A differently-spelled equivalent path must not use another lane or overtake the store.
            var second = batch.prepare(alias, 0);
            check(!second.ready, "The same normalized path bypassed its blocked predecessor");
            store.release(); ready(second);
            f.submit(second, bytes(22)); f.finish(false);
            check(f.read(x) == 22 && !second.conflict, "Same-file prepare/store order changed");
            check(f.before("release:1", f.lock(x).event(3)), "Second baseline opened before first ticket was released");
            check(f.threads.size() == 1, "Equivalent paths used more than one worker");
        }
    }

    private static void cancellationKeepsOwnership() throws Exception {
        // Cancellation during a running preparation cannot close its reference on another worker.
        try (var f = new Fixture()) {
            int x = f.firstPath(0);
            Gate blocked = f.lock(x).gate(1);
            var batch = f.begin(64);
            var first = batch.prepare(x, 0); blocked.awaitEntered();
            var queued = batch.prepare(x, 0); queued.cancel(); queued.cancel();
            first.cancel(); first.cancel();
            check(f.references.get() == 2 && !first.finished && !queued.finished,
                "Cancellation released ownership before queued/running preparation drained");
            blocked.release(); f.finish(false);
            check(f.lock(x).calls.get() == 1, "A cancelled queued preparation acquired its file lock");
            check(first.channel == null && queued.channel == null && f.read(x) == 0,
                "Cancelled preparation retained a channel or wrote data");
        }
        // Cancellation while store is entering its lock must drain before a reused-path successor.
        try (var f = new Fixture()) {
            int x = f.firstPath(1);
            var batch = f.begin(64);
            var first = batch.prepare(x, 0); ready(first);
            Gate blocked = f.lock(x).gate(2);
            f.submit(first, bytes(33)); blocked.awaitEntered(); first.cancel(); first.cancel();
            var replacement = batch.prepare(x, 0);
            check(f.references.get() == 2 && !first.finished, "Cancelled in-flight store lost ownership");
            blocked.release(); ready(replacement);
            f.submit(replacement, bytes(44)); f.finish(false);
            check(f.before("release:1", f.lock(x).event(3)), "Replacement overtook cancelled store cleanup");
            check(f.read(x) == 44 && !replacement.conflict, "Cancelled older store overwrote its successor");
        }
    }

    private static void newerVanillaWriteWins() throws Exception {
        try (var f = new Fixture()) {
            int x = f.firstPath(0);
            var batch = f.begin(64);
            var ticket = batch.prepare(x, 0); ready(ticket);
            Gate blocked = f.lock(x).gate(2);
            f.submit(ticket, bytes(55)); blocked.awaitEntered();
            f.vanilla(x, 66); blocked.release(); f.finish(false);
            check(ticket.conflict && f.read(x) == 66, "Delayed private write overwrote a newer vanilla baseline");
            // After private ownership drains, an ordinary game writer must still acquire the same lock.
            f.vanilla(x, 77);
            check(f.read(x) == 77, "Completion retained a vanilla writer's lock");
        }
    }

    private static void worldExitDrainsBothLanes() throws Exception {
        for (boolean duringStore : new boolean[]{false, true}) {
            try (var f = new Fixture()) {
                int a = f.firstPath(0), b = f.firstPath(1);
                var batch = f.begin(64);
                Gate firstGate = f.lock(a).gate(duringStore ? 2 : 1);
                Gate secondGate = f.lock(b).gate(duringStore ? 2 : 1);
                var first = batch.prepare(a, 0);
                var second = batch.prepare(b, 0);
                if (duringStore) { ready(first); ready(second); f.submit(first, bytes(88)); f.submit(second, bytes(99)); }
                firstGate.awaitEntered(); secondGate.awaitEntered();
                f.valid.set(false); f.io.close();
                check(f.references.get() == 2 && !f.io.isIdle(), "World exit abandoned accepted work");
                firstGate.release(); secondGate.release();
                f.finish(true);
                check(f.read(a) == 0 && f.read(b) == 0, "World-ended work wrote captured bytes");
                check(first.failure != null && second.failure != null, "World-ended lane did not report failure");
            }
        }
    }

    private static void freshPublicationStaysSynchronous() throws Exception {
        try (var f = new Fixture()) {
            int x = f.firstPath(1);
            Files.delete(f.path(x));
            var batch = f.begin(64);
            var ticket = batch.prepare(x, 0); ready(ticket);
            check(ticket.fresh, "Missing fixture file was not a fresh publication");
            f.submit(ticket, bytes(123));
            check(f.read(x) == 123, "Fresh file publication became deferred");
            f.finish(false);
            long[] detail = field(batch.diagnostics(), "chunkIoDetailStatsV1");
            check(detail[8] > 0 && field(batch.diagnostics(), "chunkIoStatsV1")[1] == 0,
                "Fresh synchronous publication was mixed into background store timing");
        }
    }

    private static void boundsRemainGlobal() throws Exception {
        try (var f = new Fixture()) {
            int a = f.firstPath(0), b = f.firstPath(1);
            Gate firstGate = f.lock(a).gate(1), secondGate = f.lock(b).gate(1);
            var batch = f.begin(128);
            batch.prepare(a, 0); batch.prepare(b, 0); firstGate.awaitEntered(); secondGate.awaitEntered();
            for (int i = 0; i < 30; i++) check(batch.prepare(a, 0) != null, "Pending window unexpectedly shrank");
            check(batch.prepare(b, 0) == null && f.references.get() == 32, "Two lanes doubled the 32-ticket bound");
            batch.seal(); firstGate.release(); secondGate.release(); f.finish(false);
        }
        try (var f = new Fixture()) {
            int a = f.firstPath(0), b = f.firstPath(1);
            var batch = f.begin(4);
            var first = batch.prepare(a, 0);
            var second = batch.prepare(b, 0); ready(first); ready(second);
            Gate blocked = f.lock(a).gate(2);
            f.submit(first, bytes(101)); blocked.awaitEntered();
            try { f.submit(second, bytes(102)); throw new AssertionError("Each lane incorrectly received its own byte budget"); }
            catch (IOException expected) { }
            check(batch.retainedBytes() == 4, "Failed second-lane allocation corrupted retained-byte accounting");
            f.io.close();
            check(!f.io.isIdle() && !first.finished, "Closing one failed lane abandoned the other lane's accepted work");
            try { f.io.retire(); throw new AssertionError("Retirement succeeded with a blocked accepted store"); }
            catch (IllegalStateException expected) { }
            blocked.release(); f.finish(true);
            check(f.read(a) == 101 && f.read(b) == 0, "Budget failure abandoned accepted bytes or wrote rejected bytes");
        }
    }

    private static ByteBuffer bytes(int value) { return ByteBuffer.allocate(4).putInt(value); }
    private static void ready(CooperativeChunkWrites.Ticket ticket) throws Exception {
        await(() -> ticket.ready || ticket.finished, "File preparation did not settle");
        check(ticket.ready && ticket.failure == null && !ticket.finished, "File preparation failed");
    }
    private static void await(BooleanSupplier condition, String message) throws Exception {
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (!condition.getAsBoolean()) {
            if (System.nanoTime() > until) throw new AssertionError(message);
            Thread.sleep(1);
        }
    }
    private static long[] field(String text, String name) {
        String value = Arrays.stream(text.split("; ")).filter(part -> part.startsWith(name + "="))
            .findFirst().orElseThrow().substring(name.length() + 1);
        return Arrays.stream(value.split(",")).mapToLong(Long::parseLong).toArray();
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    private static final class Gate {
        final CountDownLatch entered = new CountDownLatch(1), released = new CountDownLatch(1);
        void awaitEntered() throws Exception { check(entered.await(5, TimeUnit.SECONDS), "Independent I/O lane failed to enter its gate"); }
        void release() { released.countDown(); }
        void block() {
            entered.countDown();
            try { check(released.await(10, TimeUnit.SECONDS), "Test I/O gate was not released"); }
            catch (InterruptedException problem) { Thread.currentThread().interrupt(); throw new AssertionError(problem); }
        }
    }
    private static final class FileLock implements Lock {
        final Fixture fixture;
        final Path path;
        final ReentrantLock delegate = new ReentrantLock();
        final AtomicInteger calls = new AtomicInteger();
        final Map<Integer, Gate> gates = new ConcurrentHashMap<>();
        FileLock(Fixture fixture, Path path) { this.fixture = fixture; this.path = path; }
        Gate gate(int call) { var gate = new Gate(); check(gates.putIfAbsent(call, gate) == null, "Duplicate fixture gate"); return gate; }
        String event(int call) { return "lock:" + path.getFileName() + ":" + call; }
        public void lock() {
            int call = calls.incrementAndGet(); fixture.events.add(event(call)); fixture.threads.add(Thread.currentThread());
            Gate gate = gates.get(call); if (gate != null) gate.block();
            delegate.lock();
        }
        public void unlock() { delegate.unlock(); }
        public void lockInterruptibly() { throw new UnsupportedOperationException(); }
        public boolean tryLock() { throw new UnsupportedOperationException(); }
        public boolean tryLock(long duration, TimeUnit unit) { throw new UnsupportedOperationException(); }
        public Condition newCondition() { throw new UnsupportedOperationException(); }
    }
    private static final class Fixture implements AutoCloseable, OwnedChunkWrites.Access {
        final Path root = Files.createTempDirectory("pztools-chunk-lanes-");
        final AtomicBoolean valid = new AtomicBoolean(true);
        final AtomicInteger references = new AtomicInteger(), reservations = new AtomicInteger();
        final Map<Integer, Path> paths = new HashMap<>();
        final Map<Path, FileLock> locks = new HashMap<>();
        final List<String> events = Collections.synchronizedList(new ArrayList<>());
        final Set<Thread> threads = ConcurrentHashMap.newKeySet();
        final CooperativeChunkWrites io = new CooperativeChunkWrites(this);
        final SaveProvider.Context context = new SaveProvider.Context("lanes", "fixture", "temporary-world",
            root, Thread.currentThread(), CooperativeChunkWritesTest.class.getClassLoader(), valid);
        CooperativeChunkWrites.Batch active;
        Fixture() throws IOException { }
        int firstPath(int lane) throws IOException {
            for (int x = 0; x < 100; x++) if (Math.floorMod(path(x).hashCode(), 2) == lane) return x;
            throw new AssertionError("Could not find fixture paths on both lanes");
        }
        Path path(int x) throws IOException {
            Path existing = paths.get(x);
            if (existing != null) return existing.toAbsolutePath().normalize();
            Path value = root.resolve(x + ".bin"); Files.write(value, bytes(0).array()); paths.put(x, value); return value;
        }
        FileLock lock(int x) throws IOException { return locks.computeIfAbsent(path(x), value -> new FileLock(this, value)); }
        public File destination(int x, int y) throws Exception {
            path(x); return paths.get(x).toFile();
        }
        public OwnedChunkWrites.LockReference reserve(int x, int y) throws Exception {
            FileLock lock = lock(x); int id = reservations.incrementAndGet(); references.incrementAndGet();
            return new OwnedChunkWrites.LockReference() {
                final AtomicBoolean released = new AtomicBoolean();
                public Lock writeLock() { return lock; }
                public void close() {
                    check(released.compareAndSet(false, true), "File reference released twice");
                    check(!lock.delegate.isHeldByCurrentThread(), "Reference released before original lock unlock");
                    events.add("release:" + id); references.decrementAndGet();
                }
            };
        }
        public void synchronous(int x, int y, ByteBuffer bytes) throws Exception {
            FileLock lock = lock(x); lock.delegate.lock();
            try { Files.write(path(x), Arrays.copyOf(bytes.array(), bytes.position())); }
            finally { lock.delegate.unlock(); }
        }
        void vanilla(int x, int value) throws Exception { synchronous(x, 0, bytes(value)); }
        int read(int x) throws IOException { return ByteBuffer.wrap(Files.readAllBytes(path(x))).getInt(); }
        CooperativeChunkWrites.Batch begin(long budget) {
            check(active == null, "Fixture batch still active"); active = io.begin(context, budget, ignored -> { }); return active;
        }
        void submit(CooperativeChunkWrites.Ticket ticket, ByteBuffer bytes) throws Exception {
            io.bind(ticket); try { io.write(ticket.x, ticket.y, bytes); } finally { io.unbind(ticket); }
        }
        void finish(boolean failed) throws Exception {
            var batch = active; batch.seal();
            var task = new FutureTask<Void>(() -> { batch.await(); return null; }); Thread.ofVirtual().start(task);
            try { task.get(5, TimeUnit.SECONDS); check(!failed, "Expected I/O failure reported success"); }
            catch (ExecutionException problem) { check(failed && problem.getCause() instanceof IOException, "Unexpected I/O failure: " + problem); }
            finally { if (task.isDone()) active = null; }
            check(references.get() == 0 && batch.retainedBytes() == 0 && io.isIdle(), "Completed batch retained references, bytes or ownership");
        }
        boolean before(String first, String second) {
            synchronized (events) { int a = events.indexOf(first), b = events.indexOf(second); return a >= 0 && b > a; }
        }
        @Override public void close() throws Exception {
            for (var lock : locks.values()) for (var gate : lock.gates.values()) gate.release();
            if (active != null) finish(active.failure.get() != null);
            io.retire();
            // Executor termination can precede the worker Thread.run() epilogue by a few instructions.
            for (Thread worker : threads) { worker.join(5000); check(!worker.isAlive(), "An I/O lane survived retirement"); }
            check(references.get() == 0, "Fixture retired with held file references");
            try (var files = Files.walk(root)) {
                for (Path file : files.sorted(Comparator.reverseOrder()).toList()) Files.delete(file);
            }
        }
    }
}
