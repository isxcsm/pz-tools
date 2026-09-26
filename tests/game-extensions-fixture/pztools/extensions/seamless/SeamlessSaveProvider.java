package pztools.extensions.seamless;

import pztools.extensions.api.SaveProvider;
import java.io.IOException;
import java.nio.file.*;

/** Isolated transport fixture, never included in the product JAR or used with a real game. */
public final class SeamlessSaveProvider implements SaveProvider {
    public String id() { return "pztools.seamless-save"; }
    public Support inspect(Context context) { context.requireGameThread(); return new Support(true, null); }
    public PreparedSave capture(Context context, long maximumBytes) throws Exception {
        context.requireGameThread();
        Path root = context.sourcePath();
        Files.writeString(root.resolve("extension-identity"), context.sessionId() + "|" + context.worldId());
        Files.writeString(root.resolve("extension-started"), context.requestId());
        return new PreparedSave() {
            public long retainedBytes() { return 0; }
            public void commit() throws Exception {
                if (Thread.currentThread() == context.gameThread()) throw new AssertionError("Writer blocked game thread");
                while (!Files.exists(root.resolve("release-extension"))) {
                    if (!context.worldValid().get()) throw new IOException("Fixture world ended");
                    Thread.sleep(10);
                }
                if (Files.exists(root.resolve("fail-extension"))) throw new IOException("Fixture write failure");
                Files.writeString(root.resolve("extension-written"), context.requestId());
            }
            public void close() throws Exception { Files.writeString(root.resolve("extension-closed"), "closed"); }
        };
    }
}
