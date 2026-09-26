package pztools.extensions.api;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Objects;

/** Stable file-I/O handoff. Adapters must retain their original per-file read/write locks. */
public final class FileWriteHooks {
    public interface Handler {
        /** True only after bytes and file identity are independently owned. False preserves original I/O. */
        boolean tryDefer(File file, ByteBuffer bytes) throws IOException;
        /** Called under the original read lock, before opening or measuring the file. */
        void beforeRead(File file) throws IOException;
        /** Optional read-through of an owned immutable pending write; null retains the ordered disk read. */
        default ByteBuffer tryRead(File file, ByteBuffer destination) throws IOException { return null; }
        default void beforeSynchronousSave() { }
    }
    private static volatile Handler handler;
    private FileWriteHooks() { }
    public static synchronized void register(Handler value) {
        Objects.requireNonNull(value);
        if (handler != null) throw new IllegalStateException("File handoff already owned");
        handler = value;
    }
    public static synchronized void unregister(Handler value) {
        if (handler == value) handler = null;
    }
    public static boolean tryDefer(File file, ByteBuffer bytes) throws IOException {
        Handler current = handler;
        return current != null && current.tryDefer(file, bytes);
    }
    public static void beforeSynchronousSave() {
        Handler current = handler;
        if (current != null) current.beforeSynchronousSave();
    }
    public static ByteBuffer tryRead(File file, ByteBuffer destination) throws IOException {
        Handler current = handler;
        return current == null ? null : current.tryRead(file, destination);
    }
    public static void beforeRead(File file) throws IOException {
        Handler current = handler;
        if (current != null) current.beforeRead(file);
    }
}