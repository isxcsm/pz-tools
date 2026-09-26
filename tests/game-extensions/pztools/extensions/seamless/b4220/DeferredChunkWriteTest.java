package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.*;
import java.lang.classfile.ClassFile;
import java.lang.reflect.*;
import java.nio.*;
import java.nio.file.*;
import java.util.Arrays;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Actual transformed file operations; latches control I/O, never wall-clock performance assertions. */
public final class DeferredChunkWriteTest {
    static Class<?> fixture;
    static Path root;
    public static void main(String[] args) throws Exception {
        Path classes = Path.of(args[0]);
        root = Files.createTempDirectory("pztools-chunk-handoff-");
        class Loader extends ClassLoader {
            Class<?> define(String name, byte[] bytes) { return defineClass(name, bytes, 0, bytes.length); }
        }
        var loader = new Loader();
        loader.define("ChunkIoTemplate$Sanity", Files.readAllBytes(classes.resolve("ChunkIoTemplate$Sanity.class")));
        byte[] transformed = ChunkSaveBytecode.transform(Files.readAllBytes(classes.resolve("ChunkIoTemplate.class")), loader);
        check(ClassFile.of().verify(transformed).isEmpty(), "Transformed chunk methods must verify");
        fixture = loader.define("ChunkIoTemplate", transformed); fixture.getField("root").set(null, root.toFile());
        try {
            detachedAndOrdered();
            boundedAndNewFile();
            pendingLimitAndSaveFence();
            combinedCompletion();
            failureAndRejectedWriter();
            pinnedFileIdentity();
            check(fixture.getField("writeFinalizers").getInt(null) >= 8, "Original write finally blocks preserved");
            check(fixture.getField("readFinalizers").getInt(null) >= 2, "Original read finally blocks preserved");
            System.out.println("PASS: transformed chunk I/O, detached buffers, read/write ordering, bounds, failure and pinned file identity");
        } finally {
            try (var files = Files.list(root)) { for (Path file : files.toList()) Files.delete(file); }
            Files.delete(root);
        }
    }
    static SaveProvider.Context context() {
        return new SaveProvider.Context("chunk-request", "session", "world", root,
            Thread.currentThread(), DeferredChunkWriteTest.class.getClassLoader());
    }
    static ByteBuffer data(int value) { return ByteBuffer.allocate(4).putInt(value); }
    static void write(int x, ByteBuffer data) throws Exception { invoke("SafeWrite", x, data); }
    static int read(int x) throws Exception { return ((ByteBuffer)invoke("SafeRead", x, ByteBuffer.allocate(64))).getInt(); }
    static Object invoke(String name, int x, ByteBuffer bytes) throws Exception {
        try { return fixture.getMethod(name, int.class, int.class, ByteBuffer.class).invoke(null, x, 0, bytes); }
        catch (InvocationTargetException failure) {
            if (failure.getCause() instanceof Exception exception) throw exception;
            throw (Error)failure.getCause();
        }
    }
    static void detachedAndOrdered() throws Exception {
        write(1, data(1));
        var started = new CountDownLatch(1); var release = new CountDownLatch(1);
        AtomicReference<Throwable> error = new AtomicReference<>();
        try (var io = new DeferredChunkWrites((channel, bytes) -> {
            started.countDown(); waitFor(release); DeferredChunkWrites.writeBytes(channel, bytes);
        }); var threads = Executors.newFixedThreadPool(2)) {
            FileWriteHooks.register(io);
            var batch = io.begin(context(), 32, error::set);
            try {
                ByteBuffer live = data(2); write(1, live); waitFor(started);
                check(batch.deferred.get() == 1 && batch.retainedBytes() == 4, "Copy admitted and owned");
                live.putInt(0, 999); // The game's shared buffer is immediately reused.
                var loaded = threads.submit(() -> read(1));
                check(loaded.get(10, TimeUnit.SECONDS) == 2, "Read-through finishes while the disk write is still blocked");
                write(1, data(3));
                var latest = (ByteBuffer)invoke("SafeRead", 1, ByteBuffer.allocate(1));
                check(latest.position() == 0 && latest.limit() == 4 && latest.getInt() == 3, "Latest queued write wins; read buffer grows correctly");
                latest.putInt(0, 1111);
                check(read(1) == 3, "Game mutation cannot modify the write-back cache");
                check(ByteBuffer.wrap(Files.readAllBytes(root.resolve("1_0.bin"))).getInt() == 1,
                    "Read-through is not a false disk-commit receipt");
                batch.seal();
                var done = threads.submit(() -> { batch.await(); return true; });
                check(!done.isDone() && batch.readThrough.get() == 3, "Readers cannot finish the owned writes");
                release.countDown();
                done.get(10, TimeUnit.SECONDS);
                check(error.get() == null && batch.retainedBytes() == 0, "Successful I/O releases memory and handles");
                // Seal a second batch, then exercise ordinary saving while its earlier write is still pending.
                var entered = new CountDownLatch(1);
                var second = io.begin(context(), 32, error::set);
                write(1, data(3)); second.seal();
                threads.submit(() -> { entered.countDown(); write(1, data(4)); return true; }).get(10, TimeUnit.SECONDS);
                threads.submit(() -> { second.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(read(1) == 4, "A delayed older write cannot overwrite ordinary saving");
            } finally { release.countDown(); FileWriteHooks.unregister(io); }
        }
    }
    static void boundedAndNewFile() throws Exception {
        AtomicReference<Throwable> error = new AtomicReference<>();
        try (var io = new DeferredChunkWrites(); var thread = Executors.newSingleThreadExecutor()) {
            FileWriteHooks.register(io);
            var batch = io.begin(context(), 1, error::set);
            try {
                write(1, data(5)); write(2, data(6));
                check(batch.deferred.get() == 0 && batch.synchronous.get() == 2, "Oversized/new writes use original I/O");
                check(Files.exists(root.resolve("2_0.bin")), "Creation is visible before returning to game loaders");
                batch.seal(); thread.submit(() -> { batch.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(batch.peakBytes() <= 1 && error.get() == null, "No allocation past budget");
                var creation = io.begin(context(), 32, error::set);
                write(3, data(7)); creation.seal();
                thread.submit(() -> { creation.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(creation.deferred.get() == 0 && creation.retainedBytes() == 0, "Missing-file reservation released");
            } finally { FileWriteHooks.unregister(io); }
        }
    }
    static void failureAndRejectedWriter() throws Exception {
        AtomicReference<Throwable> error = new AtomicReference<>();
        try (var io = new DeferredChunkWrites((channel, bytes) -> { throw new IOException("synthetic disk failure"); });
             var thread = Executors.newSingleThreadExecutor()) {
            FileWriteHooks.register(io);
            var batch = io.begin(context(), 32, error::set);
            try {
                write(1, data(8)); batch.seal();
                thread.submit(() -> { batch.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(error.get() instanceof IOException && batch.retainedBytes() == 0, "Failure observed after handle release");
                io.close();
                var rejected = io.begin(context(), 32, error::set);
                write(1, data(9)); rejected.seal();
                thread.submit(() -> { rejected.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(read(1) == 9 && rejected.retainedBytes() == 0, "Rejected handoff uses ordered synchronous I/O");
            } finally { FileWriteHooks.unregister(io); }
        }
    }
    static void pinnedFileIdentity() throws Exception {
        write(4, data(10));
        var started = new CountDownLatch(1); var release = new CountDownLatch(1);
        AtomicReference<Throwable> error = new AtomicReference<>();
        try (var io = new DeferredChunkWrites((channel, bytes) -> {
            started.countDown(); waitFor(release); DeferredChunkWrites.writeBytes(channel, bytes);
        }); var thread = Executors.newSingleThreadExecutor()) {
            FileWriteHooks.register(io);
            var ctx = context(); var batch = io.begin(ctx, 32, error::set);
            try {
                write(4, data(11)); waitFor(started); batch.seal();
                Path path = root.resolve("4_0.bin"), retired = root.resolve("retired.bin");
                Files.move(path, retired);
                Files.write(path, data(12).array());
                check(io.tryRead(path.toFile(), ByteBuffer.allocate(4)) == null,
                    "A replacement path must not read the retired file's pending bytes");
                ctx.worldValid().set(false);
                var done = thread.submit(() -> { batch.await(); return true; });
                check(!done.isDone(), "World exit must not release an in-flight file write");
                release.countDown(); done.get(10, TimeUnit.SECONDS);
                check(Arrays.equals(Files.readAllBytes(path), data(12).array()), "Old write cannot target replacement path");
                check(Arrays.equals(Files.readAllBytes(retired), data(11).array()), "Write follows captured file identity");
            } finally { release.countDown(); FileWriteHooks.unregister(io); }
        }
    }
    static void pendingLimitAndSaveFence() throws Exception {
        var started = new CountDownLatch(1); var release = new CountDownLatch(1);
        AtomicReference<Throwable> error = new AtomicReference<>();
        for (int i = 0; i <= DeferredChunkWrites.MAXIMUM_PENDING; i++)
            Files.write(root.resolve((100 + i) + "_0.bin"), data(0).array());
        try (var io = new DeferredChunkWrites((channel, bytes) -> {
            started.countDown(); waitFor(release); DeferredChunkWrites.writeBytes(channel, bytes);
        }); var thread = Executors.newSingleThreadExecutor()) {
            FileWriteHooks.register(io);
            var batch = io.begin(context(), 4096, error::set);
            try {
                for (int i = 0; i <= DeferredChunkWrites.MAXIMUM_PENDING; i++) write(100 + i, data(i));
                waitFor(started); batch.seal();
                check(batch.deferred.get() == DeferredChunkWrites.MAXIMUM_PENDING && batch.synchronous.get() == 1,
                    "Queue/handle bound must fall back without dropping writes");
                var ordinarySave = thread.submit(() -> { FileWriteHooks.beforeSynchronousSave(); return true; });
                check(!ordinarySave.isDone(), "Ordinary/exit save must wait for prior detached writes");
                release.countDown(); ordinarySave.get(10, TimeUnit.SECONDS);
                thread.submit(() -> { batch.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(batch.retainedBytes() == 0 && error.get() == null, "Bounded queue fully drained");
            } finally { release.countDown(); FileWriteHooks.unregister(io); }
        }
    }
    static void combinedCompletion() throws Exception {
        var started = new CountDownLatch(1); var release = new CountDownLatch(1);
        var signals = new SaveSignals();
        try (var io = new DeferredChunkWrites((channel, bytes) -> {
            started.countDown(); waitFor(release); DeferredChunkWrites.writeBytes(channel, bytes);
        }); var thread = Executors.newSingleThreadExecutor()) {
            FileWriteHooks.register(io); signals.register();
            var ctx = context(); var receipt = signals.begin(ctx, false);
            try {
                receipt.chunks = io.begin(ctx, 32, receipt::fail);
                write(1, data(13)); waitFor(started); receipt.arm();
                GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES, null);
                var completed = thread.submit(() -> { receipt.commit(); receipt.close(); return receipt.completion(); });
                check(!completed.isDone(), "Database acknowledgement alone cannot finish file writes");
                release.countDown();
                check(completed.get(10, TimeUnit.SECONDS) == SaveProvider.Completion.GAME_SAVE_AND_PENDING_WRITES_DRAINED,
                    "Receipt must distinguish file-and-database completion");
                check(read(1) == 13, "Completion exposes the written chunk bytes");
            } finally { release.countDown(); signals.unregister(); FileWriteHooks.unregister(io); }
        }
    }
    static void waitFor(CountDownLatch latch) throws IOException {
        try { if (!latch.await(10, TimeUnit.SECONDS)) throw new IOException("Fixture latch timeout"); }
        catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IOException(failure); }
    }
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}