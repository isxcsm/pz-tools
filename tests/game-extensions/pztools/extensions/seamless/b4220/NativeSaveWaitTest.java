package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.lang.classfile.ClassFile;
import java.lang.reflect.*;
import java.net.*;
import java.nio.file.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Runs real transformation + completion policy against one isolated, gated native-worker surrogate. */
public final class NativeSaveWaitTest {
    public static void main(String[] args) throws Exception {
        Path classes = Path.of(args[0]);
        try (Fixture f = new Fixture(classes)) {
            SaveSignals.Batch batch = f.capture();
            f.await("entered");
            // This proves another task runs on the SAME game executor before the native writer can finish.
            check(f.game.submit(() -> 37).get(10, TimeUnit.SECONDS) == 37, "Game loop cannot resume");
            Future<?> completion = f.complete(batch);
            check(!completion.isDone() && f.intValue("writes") == 0, "Pending native write reported as committed");
            f.release(); completion.get(10, TimeUnit.SECONDS);
            check(f.intValue("writes") == 1 && f.populationInt("writes") == 1, "Original native write coverage changed");
            check(f.populationInt("captures") == 1 && f.populationInt("finishes") == 1, "Original capture/cleanup lost");
            check(f.objectValue("writerThread") == f.objectValue("thread"), "Native work moved to wrong thread");
        }
        try (Fixture f = new Fixture(classes)) {
            SaveSignals.Batch batch = f.capture(); f.await("entered");
            Future<?> ordinary = f.other.submit(() -> f.invoke("save"));
            Future<?> completion = f.complete(batch);
            f.release(); ordinary.get(10, TimeUnit.SECONDS); completion.get(10, TimeUnit.SECONDS);
            check(f.populationInt("captures") == 2 && f.populationInt("writesAtLastCapture") == 1,
                "Later save replaced native snapshot before preceding write completed");
        }
        try (Fixture f = new Fixture(classes)) {
            SaveSignals.Batch batch = f.capture(); f.await("entered");
            Future<?> stop = f.other.submit(() -> f.invoke("stop"));
            Future<?> completion = f.complete(batch);
            f.release(); stop.get(10, TimeUnit.SECONDS); completion.get(10, TimeUnit.SECONDS);
            check(f.intValue("writesAtStop") == 1, "World teardown overtook pending native save");
        }
        try (Fixture f = new Fixture(classes)) {
            f.type.getField("failOnce").setBoolean(f.target, true);
            SaveSignals.Batch batch = f.capture(); f.release(); f.await("failureLogged");
            Future<?> completion = f.complete(batch);
            check(!completion.isDone(), "Logged failure released still-running native work");
            f.latch("retry").countDown();
            expectFailure(completion);
            check(f.intValue("writes") == 1, "Failure handling lost the still-owned native write");
        }
        try (Fixture f = new Fixture(classes)) {
            SaveSignals.Batch batch = f.capture(); f.await("entered");
            f.context.get().worldValid().set(false);
            Future<?> completion = f.complete(batch);
            check(!completion.isDone(), "World invalidation abandoned native writer");
            f.release(); expectFailure(completion);
        }
        try (Fixture f = new Fixture(classes)) {
            SaveSignals.Batch batch = f.capture(); f.await("entered");
            AtomicReference<Throwable> failure = new AtomicReference<>();
            CountDownLatch waiting = new CountDownLatch(1), finished = new CountDownLatch(1);
            Thread waiter = new Thread(() -> {
                waiting.countDown();
                try { try { batch.commit(); } finally { batch.close(); } }
                catch (Throwable problem) { failure.set(problem); }
                finally { finished.countDown(); }
            });
            waiter.start(); check(waiting.await(10, TimeUnit.SECONDS), "Waiter did not start");
            waiter.interrupt();
            check(finished.getCount() == 1, "Cancellation released an in-flight native write");
            f.release(); check(finished.await(10, TimeUnit.SECONDS), "Cancellation did not drain");
            check(f.intValue("writes") == 1 && failure.get() instanceof InterruptedException,
                "Interrupted wait must drain before reporting cancellation");
        }
        try (Fixture f = new Fixture(classes)) {
            f.type.getField("exitWithoutAck").setBoolean(f.target, true);
            SaveSignals.Batch batch = f.capture(); f.release(); expectFailure(f.complete(batch));
            check(f.intValue("writes") == 0, "Unacknowledged thread death became success");
        }
        try (Fixture f = new Fixture(classes)) {
            f.invoke("stop");
            SaveSignals.Batch batch = f.capture(); f.complete(batch).get(10, TimeUnit.SECONDS);
            check(f.intValue("writes") == 1 && f.populationInt("writes") == 1,
                "Unavailable native worker must retain vanilla synchronous saving");
        }
        try (Fixture f = new Fixture(classes)) {
            f.release();
            f.game.submit(() -> f.invoke("save")).get(10, TimeUnit.SECONDS);
            check(f.intValue("writes") == 1 && f.populationInt("finishes") == 1,
                "No active module must preserve ordinary saving");
        }
        combinedPipeline(classes, Path.of(args[1]));
        System.out.println("PASS: native save wait handoff, original worker, ordered saves/exit, failure, world change and fallback");
    }
    private static void combinedPipeline(Path nativeClasses, Path chunkClasses) throws Exception {
        Path root = Files.createTempDirectory("pztools-combined-save-");
        var releaseFile = new CountDownLatch(1); var fileStarted = new CountDownLatch(1);
        try (Fixture f = new Fixture(nativeClasses, chunkClasses);
             var io = new DeferredChunkWrites((channel, bytes) -> {
                 fileStarted.countDown();
                 try { if (!releaseFile.await(10, TimeUnit.SECONDS)) throw new java.io.IOException("File gate timed out"); }
                 catch (InterruptedException stopped) { throw new java.io.IOException(stopped); }
                 DeferredChunkWrites.writeBytes(channel, bytes);
             })) {
            FileWriteHooks.register(io);
            try {
                Class<?> chunks = f.loader.loadClass("ChunkIoTemplate");
                chunks.getField("root").set(null, root.toFile());
                Path file = root.resolve("1_0.bin");
                Files.write(file, java.nio.ByteBuffer.allocate(4).putInt(1).array());
                SaveSignals.Batch batch = f.game.submit(() -> {
                    var context = new SaveProvider.Context("combined", "process", "world", root, Thread.currentThread(), f.loader);
                    var captured = f.signals.begin(context, true);
                    captured.nativeSave = f.nativeWait.begin(context, captured::fail);
                    captured.chunks = io.begin(context, 32, captured::fail);
                    try {
                        chunks.getMethod("SafeWrite", int.class, int.class, java.nio.ByteBuffer.class)
                            .invoke(null, 1, 0, java.nio.ByteBuffer.allocate(4).putInt(7));
                        f.invoke("save");
                    } finally { captured.arm(); }
                    return captured;
                }).get(10, TimeUnit.SECONDS);
                check(fileStarted.await(10, TimeUnit.SECONDS), "File write did not enter"); f.await("entered");
                Future<?> completed = f.complete(batch);
                int loaded = f.game.submit(() -> ((java.nio.ByteBuffer)chunks.getMethod("SafeRead", int.class, int.class,
                    java.nio.ByteBuffer.class).invoke(null, 1, 0, java.nio.ByteBuffer.allocate(4))).getInt()).get(10, TimeUnit.SECONDS);
                check(loaded == 7 && !completed.isDone(), "Game read must continue, not acknowledge pending file/native writes");
                f.release();
                f.other.submit(() -> f.nativeWait.awaitBeforeWorldSave()).get(10, TimeUnit.SECONDS);
                check(!completed.isDone(), "Native completion cannot substitute for file/database completion");
                releaseFile.countDown();
                f.other.submit(() -> { batch.chunks.await(); return true; }).get(10, TimeUnit.SECONDS);
                check(!completed.isDone(), "Written files cannot substitute for database commits");
                GameHooks.enter(SaveSignals.PLAYERS); GameHooks.exit(SaveSignals.PLAYERS, null);
                check(!completed.isDone(), "Player completion cannot substitute for vehicle completion");
                GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES, null);
                completed.get(10, TimeUnit.SECONDS);
                check(java.nio.ByteBuffer.wrap(Files.readAllBytes(file)).getInt() == 7 && batch.retainedBytes() == 0,
                    "Combined receipt requires owned bytes on disk and released handles");
            } finally {
                releaseFile.countDown(); f.release();
                for (String point : new String[]{SaveSignals.PLAYERS, SaveSignals.VEHICLES}) { GameHooks.enter(point); GameHooks.exit(point, null); }
                FileWriteHooks.unregister(io);
            }
        } finally {
            try (var files = Files.list(root)) { for (Path file : files.toList()) Files.delete(file); }
            Files.delete(root);
        }
    }
    private static void expectFailure(Future<?> work) throws Exception {
        try { work.get(10, TimeUnit.SECONDS); throw new AssertionError("Expected failed save"); }
        catch (ExecutionException expected) {
            Throwable cause = expected.getCause();
            if (!(cause instanceof RuntimeException) || !(cause.getCause() instanceof java.io.IOException)) throw expected;
        }
    }
    private static void check(boolean value, String text) { if (!value) throw new AssertionError(text); }
    private static final class Loader extends URLClassLoader {
        Loader(Path directory, Path chunkDirectory) throws Exception {
            super(chunkDirectory == null ? new URL[]{directory.toUri().toURL()}
                : new URL[]{directory.toUri().toURL(), chunkDirectory.toUri().toURL()}, NativeSaveWaitTest.class.getClassLoader());
        }
        protected Class<?> findClass(String name) throws ClassNotFoundException {
            if (!name.equals("zombie.MapCollisionData") && !name.equals("ChunkIoTemplate")) return super.findClass(name);
            try (var in = getResourceAsStream(name.replace('.', '/') + ".class")) {
                byte[] original = in.readAllBytes();
                byte[] code = name.equals("ChunkIoTemplate") ? ChunkSaveBytecode.transform(original, this)
                    : NativeSaveBytecode.transform(original, this);
                var errors = ClassFile.of().verify(code);
                if (!errors.isEmpty()) throw new AssertionError(errors.toString());
                return defineClass(name, code, 0, code.length);
            } catch (java.io.IOException failure) { throw new ClassNotFoundException(name, failure); }
        }
    }
    private static final class Fixture implements AutoCloseable {
        final Loader loader;
        final Class<?> type;
        final Object target, population;
        final NativeSaveWait nativeWait;
        final SaveSignals signals = new SaveSignals();
        final ExecutorService game = Executors.newSingleThreadExecutor(), other = Executors.newCachedThreadPool();
        final AtomicReference<SaveProvider.Context> context = new AtomicReference<>();
        Fixture(Path directory) throws Exception { this(directory, null); }
        Fixture(Path directory, Path chunkDirectory) throws Exception {
            loader = new Loader(directory, chunkDirectory); type = loader.loadClass("zombie.MapCollisionData");
            target = type.getConstructor().newInstance();
            population = loader.loadClass("zombie.popman.ZombiePopulationManager").getField("instance").get(null);
            nativeWait = new NativeSaveWait(loader); signals.nativeWait = nativeWait;
            signals.register(); SaveWaitHooks.register(nativeWait);
        }
        SaveSignals.Batch capture() throws Exception {
            return game.submit(() -> {
                var ctx = new SaveProvider.Context("request", "process", "world", Path.of(".").toAbsolutePath(), Thread.currentThread(), loader);
                context.set(ctx);
                var batch = signals.begin(ctx, true);
                batch.nativeSave = nativeWait.begin(ctx, batch::fail);
                try { invoke("save"); } finally { batch.arm(); }
                // Post-capture drains finish early; they must not substitute for native completion.
                for (String point : new String[]{SaveSignals.PLAYERS, SaveSignals.VEHICLES}) {
                    GameHooks.enter(point); GameHooks.exit(point, null);
                }
                return batch;
            }).get(10, TimeUnit.SECONDS);
        }
        Future<?> complete(SaveSignals.Batch batch) {
            return other.submit(() -> {
                try { try { batch.commit(); } finally { batch.close(); } }
                catch (Exception failure) { throw new RuntimeException(failure); }
            });
        }
        void invoke(String method) {
            try { type.getMethod(method).invoke(target); }
            catch (ReflectiveOperationException failure) { throw new RuntimeException(failure); }
        }
        Object objectValue(String field) throws Exception { return type.getField(field).get(target); }
        int intValue(String field) throws Exception { return type.getField(field).getInt(target); }
        int populationInt(String field) throws Exception { return population.getClass().getField(field).getInt(population); }
        CountDownLatch latch(String field) throws Exception { return (CountDownLatch)objectValue(field); }
        void await(String field) throws Exception { check(latch(field).await(10, TimeUnit.SECONDS), "Fixture signal missing: " + field); }
        void release() throws Exception { latch("release").countDown(); }
        public void close() throws Exception {
            release(); latch("retry").countDown();
            // Unblock only test-owned gates; never interrupt an in-flight simulated write.
            game.shutdown(); other.shutdown();
            check(game.awaitTermination(10, TimeUnit.SECONDS), "Game fixture did not stop");
            check(other.awaitTermination(10, TimeUnit.SECONDS), "Completion fixture did not stop");
            invoke("stop"); SaveWaitHooks.unregister(nativeWait); signals.unregister(); loader.close();
        }
    }
}
