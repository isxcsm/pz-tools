package pztools.extensions.fixture;

import pztools.extensions.api.SaveProvider;
import pztools.extensions.runtime.CooperativeCapture;
import java.io.IOException;
import java.nio.file.*;

/** Isolated transport fixture, never included in the product JAR or used with a real game. */
public final class TestSaveProvider implements SaveProvider {
    private final String generation = java.util.UUID.randomUUID().toString();
    public boolean supportsReload() { return true; }
    public void close() { }
    public String id() { return "pztools.test-save"; }
    public Support inspect(Context context) { context.requireGameThread(); return new Support(true, null); }
    public boolean readyToCapture(Context context) throws Exception {
        context.requireGameThread();
        Path root = context.sourcePath();
        if (!Files.exists(root.resolve("block-preparation"))) return true;
        if (!Files.exists(root.resolve("preparation-waiting"))) Files.writeString(root.resolve("preparation-waiting"), "waiting");
        return false;
    }
    public PreparedSave capture(Context context, long maximumBytes) throws Exception {
        context.requireGameThread();
        if (!Files.exists(context.sourcePath().resolve("cooperative-fixture"))) return captureOnce(context);
        return new CooperativeCapture() {
            private PreparedSave prepared;
            private int steps;
            public boolean advance(long budget) throws Exception {
                context.requireGameThread();
                Path root = context.sourcePath();
                if (Files.exists(root.resolve("block-cooperative"))) {
                    if (!Files.exists(root.resolve("cooperative-waiting"))) Files.writeString(root.resolve("cooperative-waiting"), "waiting");
                    return false;
                }
                if (++steps < 6) return false;
                prepared = captureOnce(context);
                return true;
            }
            public void abort(Throwable failure) { }
            public long retainedBytes() { return 0; }
            public String diagnostics() { return "cooperativeFixtureSteps=" + steps + "; " + (prepared == null ? "" : prepared.diagnostics()); }
            public void commit() throws Exception { if (prepared == null) throw new IOException("Incomplete cooperative fixture"); prepared.commit(); }
            public void close() throws Exception { if (prepared != null) prepared.close(); }
        };
    }
    private PreparedSave captureOnce(Context context) throws Exception {
        context.requireGameThread();
        Path root = context.sourcePath();
        if (Files.exists(root.resolve("flush-game")))
            Class.forName("zombie.GameWindow", false, context.gameClasses()).getMethod("save", boolean.class).invoke(null, true);
        Files.writeString(root.resolve("extension-identity"), context.sessionId() + "|" + context.worldId());
        Files.writeString(root.resolve("extension-started"), context.requestId());
        String detail = "fixtureCapture=complete; fixtureGeneration=" + generation;
        return new PreparedSave() {
            public long retainedBytes() { return 0; }
            public String diagnostics() { return detail; }
            public void commit() throws Exception {
                if (Thread.currentThread() == context.gameThread()) throw new AssertionError("Writer blocked game thread");
                while (!Files.exists(root.resolve("release-extension"))) {
                    if (!context.worldValid().get()) throw new IOException("Fixture world ended");
                    Thread.sleep(10);
                }
                if (Files.exists(root.resolve("fail-extension"))) throw new IOException("Fixture write failure");
                if (Files.exists(root.resolve("unsupported-extension"))) failUnsupportedOperation();
                Files.writeString(root.resolve("extension-written"), context.requestId());
            }
            public void close() throws Exception { Files.writeString(root.resolve("extension-closed"), "closed"); }
        };
    }
    private static void failUnsupportedOperation() { throw new UnsupportedOperationException(); }
}
