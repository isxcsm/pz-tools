package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.*;
import java.lang.invoke.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Private body + production file locks + untouched ordinary saves. All data and classes are synthetic. */
public final class PrivateSaveEntryTest {
    public static void main(String[] args) throws Throwable {
        Path root = Files.createTempDirectory("pztools-private-entry-");
        try (var loader = new URLClassLoader(new URL[]{Path.of(args[0]).toUri().toURL()}, PrivateSaveEntryTest.class.getClassLoader());
             var completion = Executors.newSingleThreadExecutor(); var reader = Executors.newSingleThreadExecutor()) {
            Class<?> window = loader.loadClass("zombie.GameWindow"), chunk = loader.loadClass("zombie.iso.IsoChunk");
            Class<?> names = loader.loadClass("zombie.ChunkMapFilenames"), thumbnail = loader.loadClass("zombie.savefile.SavefileThumbnail");
            names.getField("root").set(null, root.toFile());
            Map<String, byte[]> sources = new HashMap<>();
            for (var m : PrivateSaveGraph.SOURCES) sources.put(m.owner(), Files.readAllBytes(Path.of(args[0]).resolve(m.owner() + ".class")));
            invoke(window.getMethod("save", boolean.class), null, true);
            check(thumbnail.getField("renders").getInt(null) == 1 && read(chunk) == 1, "Vanilla baseline changed");
            CountDownLatch writing = new CountDownLatch(1), release = new CountDownLatch(1);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            try (var io = new OwnedChunkWrites(new GameChunkAccess(loader), (file, bytes) -> {
                writing.countDown(); waitFor(release); OwnedChunkWrites.writeBytes(file, bytes);
            })) {
                MethodHandle sink = MethodHandles.lookup().findVirtual(OwnedChunkWrites.class, "write",
                    MethodType.methodType(void.class, int.class, int.class, ByteBuffer.class)).bindTo(io);
                PrivateSaveGraph entry = PrivateSaveGraph.create(loader, sources, sink);
                var ctx = new SaveProvider.Context("request", "session", "world", root, Thread.currentThread(), loader);
                var batch = io.begin(ctx, 1024, failure::set);
                try {
                    entry.saveForBackup(); batch.seal(); waitFor(writing);
                    check(thumbnail.getField("renders").getInt(null) == 1, "Private entry leaked into preview or called ordinary root");
                    Future<?> done = completion.submit(() -> { batch.await(); return null; });
                    CountDownLatch tryingRead = new CountDownLatch(1);
                    Future<Integer> read = reader.submit(() -> { tryingRead.countDown(); return read(chunk); });
                    waitFor(tryingRead);
                    check(!done.isDone() && !read.isDone(), "Public unmodified reader bypassed original file lock");
                    release.countDown(); done.get(10, TimeUnit.SECONDS);
                    check(read.get(10, TimeUnit.SECONDS) == 2 && failure.get() == null, "Reader missed completed private bytes");
                    invoke(window.getMethod("save", boolean.class), null, true);
                    check(read(chunk) == 3 && thumbnail.getField("renders").getInt(null) == 2, "Normal save was rerouted after extension");
                    // OnSave is ordinary mod code: its nested save MUST NOT inherit private thumbnail/I/O routing.
                    AtomicInteger nested = new AtomicInteger();
                    window.getField("onSave").set(null, (Runnable)() -> {
                        try { window.getField("onSave").set(null, null); invoke(window.getMethod("save", boolean.class), null, true); nested.incrementAndGet(); }
                        catch (Exception problem) { throw new RuntimeException(problem); }
                    });
                    var next = io.begin(ctx, 1024, failure::set);
                    entry.saveForBackup(); next.seal(); completion.submit(() -> { next.await(); return null; }).get(10, TimeUnit.SECONDS);
                    check(nested.get() == 1 && thumbnail.getField("renders").getInt(null) == 3 && read(chunk) == 5,
                        "Nested mod save inherited extension behavior or original side effects were duplicated");
                    // A mod subclass must retain its virtual override, not be forced through a copied base body.
                    Class<?> world = loader.loadClass("zombie.iso.IsoWorld");
                    Object cell = world.getField("currentCell").get(world.getField("instance").get(null));
                    Object map = cell.getClass().getMethod("map").invoke(cell);
                    Class<?> modded = loader.loadClass("zombie.iso.IsoChunk$Modded");
                    map.getClass().getMethod("setChunk", chunk).invoke(map, modded.getConstructor().newInstance());
                    var override = io.begin(ctx, 1024, failure::set);
                    entry.saveForBackup(); override.seal(); completion.submit(() -> { override.await(); return null; }).get(10, TimeUnit.SECONDS);
                    check(modded.getField("overrides").getInt(null) == 1 && read(chunk) == 900, "Mod virtual override was bypassed");
                    check(chunk.getMethod("references").invoke(null).equals(0), "Original counted lock reference leaked");
                    check(Arrays.equals((int[])window.getMethod("stages").invoke(null), new int[]{6,6}), "Original pre/post-save coverage changed");
                } finally { release.countDown(); }
            }
            verifyFailureAndOrdering(loader, root, chunk, completion, reader);
            verifyBoundedIndependentCaptures(loader, root, chunk, completion);
            verifyLockAdmissionFailure(loader, root, completion);
            System.out.println("PASS: private save isolation, bounded independent captures, single disk writer, fallback, failure and shutdown");
        } finally {
            try (var paths = Files.walk(root)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
    }
    private static void verifyFailureAndOrdering(ClassLoader loader, Path root, Class<?> chunk,
            ExecutorService completion, ExecutorService other) throws Exception {
        AtomicReference<Throwable> error = new AtomicReference<>();
        var ctx = new SaveProvider.Context("failure", "session", "world", root, Thread.currentThread(), loader);
        CountDownLatch writing = new CountDownLatch(1), release = new CountDownLatch(1);
        try (var io = new OwnedChunkWrites(new GameChunkAccess(loader), (file, bytes) -> {
            writing.countDown(); waitFor(release); OwnedChunkWrites.writeBytes(file, bytes);
        })) {
            var batch = io.begin(ctx, 16, error::set);
            try {
                io.write(0,0, ByteBuffer.allocate(4).putInt(41)); waitFor(writing); batch.seal();
                CountDownLatch attempted = new CountDownLatch(1);
                Future<?> vanilla = other.submit(() -> { attempted.countDown(); invoke(chunk.getMethod("SafeWrite", int.class,int.class,ByteBuffer.class), null,0,0,ByteBuffer.allocate(4).putInt(42)); return null; });
                waitFor(attempted); check(!vanilla.isDone(), "New vanilla write overtook admitted older write");
                ctx.worldValid().set(false);
                Future<?> done = completion.submit(() -> { batch.await(); return null; });
                check(!done.isDone(), "World exit released writer ownership");
                release.countDown(); done.get(10,TimeUnit.SECONDS); vanilla.get(10,TimeUnit.SECONDS);
                check(read(chunk) == 42, "Private background write overwrote later normal save");
            } finally { release.countDown(); }
        }
        var failContext = new SaveProvider.Context("failure2", "session", "world", root, Thread.currentThread(), loader);
        try (var io = new OwnedChunkWrites(new GameChunkAccess(loader), (file, bytes) -> { throw new IOException("disk failure"); })) {
            var batch = io.begin(failContext, 16, error::set); io.write(0,0,ByteBuffer.allocate(4).putInt(50)); batch.seal();
            expectWriteFailure(completion.submit(() -> { batch.await(); return null; }));
            check(error.get() instanceof IOException && batch.retainedBytes() == 0 && chunk.getMethod("references").invoke(null).equals(0), "Failed write leaked memory/lock or was unreported");
        }
    }
    private static void verifyBoundedIndependentCaptures(ClassLoader loader, Path root, Class<?> chunk,
            ExecutorService completion) throws Exception {
        // Many different chunks must hand off while the first physical write is stopped. This failed
        // with a single thread owning both every lock and disk execution; no elapsed-time assertion.
        for (int x = 1; x <= OwnedChunkWrites.MAXIMUM_PENDING + 2; x++)
            invoke(chunk.getMethod("SafeWrite", int.class, int.class, ByteBuffer.class), null, x, 0, ByteBuffer.allocate(4).putInt(-1));
        var writing = new CountDownLatch(1); var release = new CountDownLatch(1);
        var maxIo = new AtomicInteger(); var activeIo = new AtomicInteger(); var writes = new AtomicInteger();
        var failure = new AtomicReference<Throwable>();
        try (var game = Executors.newSingleThreadExecutor();
             var io = new OwnedChunkWrites(new GameChunkAccess(loader), (file, bytes) -> {
                 int count = activeIo.incrementAndGet(); maxIo.accumulateAndGet(count, Math::max);
                 try { writing.countDown(); waitFor(release); OwnedChunkWrites.writeBytes(file, bytes); writes.incrementAndGet(); }
                 finally { activeIo.decrementAndGet(); }
             })) {
            try {
                var capture = game.submit(() -> {
                    var ctx = new SaveProvider.Context("many", "session", "world", root, Thread.currentThread(), loader);
                    var batch = io.begin(ctx, (OwnedChunkWrites.MAXIMUM_PENDING + 1L) * 4, failure::set);
                    ByteBuffer shared = ByteBuffer.allocate(4);
                    for (int x = 1; x <= OwnedChunkWrites.MAXIMUM_PENDING + 1; x++) {
                        shared.clear().putInt(x); io.write(x, 0, shared); shared.putInt(0, -99);
                    }
                    batch.seal(); return batch;
                });
                waitFor(writing);
                var batch = capture.get(10, TimeUnit.SECONDS); // Disk gate is still CLOSED here.
                check(writes.get() == 0, "Capture secretly waited for disk completion");
                check(batch.pendingCount() == OwnedChunkWrites.MAXIMUM_PENDING,
                    "Operation bound was not enforced before allocating another owner/channel");
                check(batch.retainedBytes() == 4L * OwnedChunkWrites.MAXIMUM_PENDING, "Retained immutable bytes differ from admitted work");
                check(readAt(chunk, OwnedChunkWrites.MAXIMUM_PENDING + 1) == OwnedChunkWrites.MAXIMUM_PENDING + 1,
                    "Capacity fallback lost the final chunk instead of using the original writer");
                Future<?> done = completion.submit(() -> { batch.await(); return null; });
                check(!done.isDone(), "Snapshot copies were mistaken for written files");
                // Stop future submissions while all of these already-admitted owners remain valid.
                io.close(); check(!done.isDone(), "Shutdown abandoned captured data");
                release.countDown(); done.get(10, TimeUnit.SECONDS);
                check(maxIo.get() == 1 && writes.get() == OwnedChunkWrites.MAXIMUM_PENDING,
                    "Parallel lock ownership must not multiply disk writers");
                check(batch.pendingCount() == 0 && batch.retainedBytes() == 0 && failure.get() == null,
                    "Batch did not release all data/locks after closing");
                for (int x = 1; x <= OwnedChunkWrites.MAXIMUM_PENDING; x++)
                    check(readAt(chunk, x) == x, "Reused scratch buffer leaked into captured chunk " + x);
                check(chunk.getMethod("references").invoke(null).equals(0), "A counted vanilla lock leaked");
            } finally { release.countDown(); }
        }
        // Byte pressure uses the same policy, independently of the operation-count bound.
        var byteRelease = new CountDownLatch(1); var byteStarted = new CountDownLatch(1);
        try (var game = Executors.newSingleThreadExecutor();
             var io = new OwnedChunkWrites(new GameChunkAccess(loader), (file, bytes) -> {
                 byteStarted.countDown(); waitFor(byteRelease); OwnedChunkWrites.writeBytes(file, bytes);
             })) {
            try {
                var capture = game.submit(() -> {
                    var ctx = new SaveProvider.Context("bytes", "session", "world", root, Thread.currentThread(), loader);
                    var batch = io.begin(ctx, 4, failure::set);
                    io.write(1,0,ByteBuffer.allocate(4).putInt(81));
                    io.write(2,0,ByteBuffer.allocate(4).putInt(82)); batch.seal(); return batch;
                });
                waitFor(byteStarted); var batch = capture.get(10, TimeUnit.SECONDS);
                check(batch.retainedBytes() == 4 && batch.pendingCount() == 1 && readAt(chunk,2) == 82,
                    "Byte-limit fallback was not synchronous/complete");
                byteRelease.countDown(); completion.submit(() -> { batch.await(); return null; }).get(10,TimeUnit.SECONDS);
                check(readAt(chunk,1) == 81 && batch.retainedBytes() == 0, "Byte-limited batch failed to settle");
            } finally { byteRelease.countDown(); }
        }
    }
    private static void verifyLockAdmissionFailure(ClassLoader loader, Path root, ExecutorService completion) throws Exception {
        var base = new GameChunkAccess(loader); var closed = new AtomicInteger(); var failure = new AtomicReference<Throwable>();
        OwnedChunkWrites.Access access = new OwnedChunkWrites.Access() {
            public File destination(int x,int y) throws Exception { return base.destination(x,y); }
            public OwnedChunkWrites.LockReference reserve(int x,int y) {
                return new OwnedChunkWrites.LockReference() {
                    public java.util.concurrent.locks.Lock writeLock() { throw new IllegalStateException("fixture lock failure"); }
                    public void close() { closed.incrementAndGet(); }
                };
            }
            public void synchronous(int x,int y,ByteBuffer bytes) { throw new AssertionError("An admitted failure must not replay vanilla writing"); }
        };
        try (var io = new OwnedChunkWrites(access)) {
            var ctx = new SaveProvider.Context("lock-failure", "session", "world", root, Thread.currentThread(), loader);
            var batch = io.begin(ctx,4,failure::set);
            try { io.write(1,0,ByteBuffer.allocate(4).putInt(83)); throw new AssertionError("Unowned lock accepted"); }
            catch (IOException expected) { }
            batch.seal(); expectWriteFailure(completion.submit(() -> { batch.await(); return null; }));
            check(closed.get() == 1 && batch.pendingCount() == 0 && batch.retainedBytes() == 0 && failure.get() != null,
                "Failed lock admission did not release its sole reference/input");
        }
    }
    private static void expectWriteFailure(Future<?> result) throws Exception {
        try { result.get(10,TimeUnit.SECONDS); throw new AssertionError("Failed capture reported success"); }
        catch (ExecutionException expected) { check(expected.getCause() instanceof IOException, "Expected owned I/O failure"); }
    }
    private static int readAt(Class<?> chunk, int x) throws Exception {
        return ((ByteBuffer)invoke(chunk.getMethod("SafeRead",int.class,int.class,ByteBuffer.class), null,x,0,ByteBuffer.allocate(4))).getInt();
    }
    private static int read(Class<?> chunk) throws Exception { return ((ByteBuffer)invoke(chunk.getMethod("SafeRead",int.class,int.class,ByteBuffer.class), null,0,0,ByteBuffer.allocate(4))).getInt(); }
    private static Object invoke(Method method, Object receiver, Object... args) throws Exception {
        try { return method.invoke(receiver,args); }
        catch (InvocationTargetException failed) { if(failed.getCause() instanceof Exception e) throw e; throw (Error)failed.getCause(); }
    }
    private static void waitFor(CountDownLatch latch) throws IOException {
        try { if (!latch.await(10,TimeUnit.SECONDS)) throw new IOException("Fixture did not signal"); }
        catch (InterruptedException e) { throw new IOException(e); }
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
