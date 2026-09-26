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
            System.out.println("PASS: private save entry, original/nested/modded saves, pinned locks, I/O failure and ownership");
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
            completion.submit(() -> { batch.await(); return null; }).get(10,TimeUnit.SECONDS);
            check(error.get() instanceof IOException && batch.retainedBytes() == 0 && chunk.getMethod("references").invoke(null).equals(0), "Failed write leaked memory/lock or was unreported");
        }
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
