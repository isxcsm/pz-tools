import pztools.extensions.api.SaveProvider;
import pztools.extensions.runtime.CheckpointRuntime;
import pztools.extensions.seamless.SeamlessSaveProvider;
import java.nio.file.*;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Small deterministic behavior harness; no real game, wall-clock performance assertion or source-text checks. */
public final class CheckpointRuntimeTest {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("pztools-checkpoint-");
        var context = new SaveProvider.Context("request-1", "session-1", "world-1", directory,
            Thread.currentThread(), CheckpointRuntimeTest.class.getClassLoader());
        try {
            check(!new SeamlessSaveProvider().inspect(context).supported(), "Unqualified module must remain unavailable");
            var writing = new CountDownLatch(1);
            var release = new CountDownLatch(1);
            var disposed = new AtomicInteger();
            byte[] live = new byte[] { 1, 2, 3 };
            var adapter = new SeamlessSaveProvider.GameAdapter() {
                public SaveProvider.Support inspect(SaveProvider.Context ignored) { return new SaveProvider.Support(true, null); }
                public SaveProvider.PreparedSave capture(SaveProvider.Context ctx, long budget) {
                    ctx.requireGameThread();
                    byte[] frozen = live.clone();
                    return new SaveProvider.PreparedSave() {
                        public long retainedBytes() { return frozen.length; }
                        public void commit() throws Exception {
                            check(Thread.currentThread() != ctx.gameThread(), "Disk work must leave game thread");
                            writing.countDown();
                            if (!release.await(10, TimeUnit.SECONDS)) throw new AssertionError("Fixture release timed out");
                            Files.write(directory.resolve("saved.bin"), frozen);
                        }
                        public void close() { disposed.incrementAndGet(); }
                    };
                }
            };
            try (var runtime = new CheckpointRuntime(1024)) {
                var provider = new SeamlessSaveProvider(List.of(adapter));
                var job = runtime.begin(provider, context);
                try {
                    check(writing.await(10, TimeUnit.SECONDS), "Writer must start");
                    check(job.poll() == null, "A dequeued write is not completed");
                    live[0] = 9;
                    check(!job.cancelBeforeWrite(), "Running I/O is not force-cancelled");
                    try { runtime.begin(provider, context); throw new AssertionError("Overlapping checkpoint accepted"); }
                    catch (IllegalStateException expected) { }
                } finally { release.countDown(); }
                await(job);
                check(job.poll().phase() == CheckpointRuntime.Phase.COMMITTED, "Commit receipt required");
                check(disposed.get() == 1, "Snapshot released once before completion");
                check(Files.readAllBytes(directory.resolve("saved.bin"))[0] == 1, "Write must use detached snapshot");
                check(job.poll().sessionId().equals("session-1"), "Completion retains world/session identity");
            }
            var failedAdapter = new SeamlessSaveProvider.GameAdapter() {
                public SaveProvider.Support inspect(SaveProvider.Context ctx) { return new SaveProvider.Support(true, null); }
                public SaveProvider.PreparedSave capture(SaveProvider.Context ctx, long budget) {
                    return new SaveProvider.PreparedSave() {
                        public long retainedBytes() { return 1; }
                        public void commit() throws Exception { throw new java.io.IOException("fixture disk failure"); }
                        public void close() { disposed.incrementAndGet(); }
                    };
                }
            };
            try (var runtime = new CheckpointRuntime(1)) {
                var job = runtime.begin(new SeamlessSaveProvider(List.of(failedAdapter)), context);
                await(job);
                check(job.poll().phase() == CheckpointRuntime.Phase.FAILED, "Failed write is never a success receipt");
                check(job.poll().error() instanceof java.io.IOException, "Failure cause preserved");
            }
            try (var runtime = new CheckpointRuntime(1)) {
                var oversized = runtime.begin(new SeamlessSaveProvider(List.of(adapter)), context);
                await(oversized);
                check(oversized.poll().phase() == CheckpointRuntime.Phase.FAILED
                    && oversized.poll().error() instanceof IllegalStateException, "Oversized snapshot cannot commit");
            }
            failedCaptureCleanupIsOwned(context);
            pztools.extensions.seamless.b4220.CooperativeCaptureTest.run();
            ModuleReloadTest.run();
        pztools.extensions.runtime.ContinuousRuntimeTest.run();
        pztools.extensions.runtime.VehicleHooksTest.run();
            System.out.println("PASS: unsupported adapter, detached capture, writer ownership, failure and memory budget");
        } finally {
            Files.deleteIfExists(directory.resolve("saved.bin"));
            Files.delete(directory);
        }
    }
    private static void failedCaptureCleanupIsOwned(SaveProvider.Context context) throws Exception {
        var closing = new CountDownLatch(1); var release = new CountDownLatch(1);
        try (var runtime = new CheckpointRuntime(1)) {
            var provider = new SaveProvider() {
                public String id() { return "fixture.cleanup"; }
                public Support inspect(Context ctx) { return new Support(true, null); }
                public PreparedSave capture(Context ctx, long budget) {
                    runtime.close(); // Shutdown races capture, but the completion worker was already admitted.
                    return new PreparedSave() {
                        public long retainedBytes() { return 2; } // Fail after acquiring a snapshot.
                        public void commit() { throw new AssertionError("Rejected capture was committed"); }
                        public void close() throws Exception {
                            check(Thread.currentThread() != ctx.gameThread(), "Failure cleanup must not block game thread");
                            closing.countDown();
                            if (!release.await(10, TimeUnit.SECONDS)) throw new AssertionError("Fixture close timeout");
                        }
                    };
                }
            };
            var failed = runtime.begin(provider, context);
            try {
                check(closing.await(10, TimeUnit.SECONDS), "Cleanup starts even during shutdown");
                check(failed.poll() == null, "Failed capture still owns unfinished cleanup");
                try { runtime.begin(provider, context); throw new AssertionError("Closing runtime accepted a new save"); }
                catch (IllegalStateException expected) { }
            } finally { release.countDown(); }
            await(failed);
            check(failed.poll().phase() == CheckpointRuntime.Phase.FAILED, "Failure is published only after cleanup");
        }
    }
    private static void await(CheckpointRuntime.Job job) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (job.poll() == null) {
            if (System.nanoTime() >= deadline) throw new AssertionError("Fixture completion timed out");
            Thread.sleep(1);
        }
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
