package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.io.IOException;
import java.nio.file.Path;
import java.util.concurrent.*;

public final class SaveAdapterBehaviorTest {
    public static void main(String[] args) throws Exception {
        var signals = new SaveSignals();
        signals.register();
        try {
            var context = context();
            var batch = signals.begin(context, true);
            check(GameHooks.suppress(SaveSignals.THUMBNAIL), "Only the module capture suppresses its preview");
            var offThread = new FutureTask<Boolean>(() -> GameHooks.suppress(SaveSignals.THUMBNAIL));
            new Thread(offThread).start();
            check(!offThread.get(10, TimeUnit.SECONDS), "Another thread's preview is unaffected");
            GameHooks.enter(SaveSignals.PLAYERS); // This drain started before the capture boundary.
            batch.arm();
            check(!GameHooks.suppress(SaveSignals.THUMBNAIL), "Normal rendering resumes after capture");
            var result = write(batch);
            GameHooks.exit(SaveSignals.PLAYERS, null);
            drain(SaveSignals.VEHICLES);
            check(!result.isDone(), "A pre-boundary drain cannot acknowledge the captured player");
            GameHooks.enter(SaveSignals.PLAYERS);
            check(!result.isDone(), "Dequeued or running is not completed");
            GameHooks.exit(SaveSignals.PLAYERS, null);
            result.get(10, TimeUnit.SECONDS);
            var failed = signals.begin(context(), true);
            failed.arm();
            var failureResult = write(failed);
            GameHooks.enter(SaveSignals.PLAYERS);
            GameHooks.error(SaveSignals.ERRORS, new IOException("Simulated internally logged database rollback"));
            GameHooks.exit(SaveSignals.PLAYERS, null);
            drain(SaveSignals.VEHICLES);
            try { failureResult.get(10, TimeUnit.SECONDS); throw new AssertionError("Logged failure reported success"); }
            catch (ExecutionException expected) { check(expected.getCause() instanceof IOException, "Save error retained"); }
            var changedContext = context();
            var ended = signals.begin(changedContext, false);
            ended.arm();
            changedContext.worldValid().set(false);
            try { write(ended).get(10, TimeUnit.SECONDS); throw new AssertionError("Ended world reported success"); }
            catch (ExecutionException expected) { check(expected.getCause() instanceof IOException, "World end retained"); }
            System.out.println("PASS: preview scope, post-capture drains, in-flight writes, logged error, world end");
        } finally { signals.unregister(); }
    }
    private static SaveProvider.Context context() {
        return new SaveProvider.Context("r", "s", "w", Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath(),
            Thread.currentThread(), SaveAdapterBehaviorTest.class.getClassLoader());
    }
    private static FutureTask<Void> write(SaveProvider.PreparedSave save) {
        var task = new FutureTask<Void>(() -> { try (save) { save.commit(); } return null; });
        Thread worker = new Thread(task, "fixture-writer"); worker.setDaemon(true); worker.start();
        return task;
    }
    private static void drain(String point) { GameHooks.enter(point); GameHooks.exit(point, null); }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
