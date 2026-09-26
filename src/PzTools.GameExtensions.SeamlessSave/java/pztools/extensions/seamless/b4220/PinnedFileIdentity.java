package pztools.extensions.seamless.b4220;

import java.io.*;
import java.lang.instrument.Instrumentation;
import java.lang.invoke.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.*;

/** JDK-25 adapter detail. Windows BasicFileAttributes.fileKey() is null; compare identities of OPEN handles instead. */
final class PinnedFileIdentity {
    private static volatile MethodHandle keyReader = resolve();
    private PinnedFileIdentity() { }
    static void initialize(Instrumentation instrumentation) {
        if (keyReader != null) return;
        Module base = FileChannel.class.getModule(), target = PinnedFileIdentity.class.getModule();
        // Open only this JDK implementation package to this trusted module, not ALL-UNNAMED or game code.
        if (instrumentation.isModifiableModule(base))
            instrumentation.redefineModule(base, Set.of(), Map.of(), Map.of("sun.nio.ch", Set.of(target)), Set.of(), Map.of());
        keyReader = resolve(); // Unavailable layout disables read-through; ordered disk I/O is still correct.
    }
    private static MethodHandle resolve() {
        try {
            Class<?> channel = Class.forName("sun.nio.ch.FileChannelImpl");
            var descriptor = channel.getDeclaredField("fd");
            var create = Class.forName("sun.nio.ch.FileKey").getDeclaredMethod("create", FileDescriptor.class);
            if (!descriptor.trySetAccessible() || !create.trySetAccessible()) return null;
            MethodHandle get = MethodHandles.lookup().unreflectGetter(descriptor)
                .asType(MethodType.methodType(FileDescriptor.class, FileChannel.class));
            MethodHandle make = MethodHandles.lookup().unreflect(create)
                .asType(MethodType.methodType(Object.class, FileDescriptor.class));
            return MethodHandles.filterReturnValue(get, make);
        } catch (ReflectiveOperationException | RuntimeException | LinkageError unsupported) { return null; }
    }
    static Object key(FileChannel channel) throws IOException {
        MethodHandle reader = keyReader;
        if (reader == null) return null;
        try { return (Object)reader.invokeExact(channel); }
        catch (IOException failure) { throw failure; }
        catch (Throwable failure) { throw new IOException("Cannot read pinned file identity", failure); }
    }
    static boolean matches(Path path, Object identity) throws IOException {
        if (identity == null) return false;
        try (FileChannel current = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            return identity.equals(key(current));
        }
    }
}