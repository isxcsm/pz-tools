package pztools.extensions.seamless.b4220;

import java.io.File;
import java.lang.invoke.*;
import java.lang.reflect.*;
import java.nio.ByteBuffer;
import java.util.concurrent.locks.*;

/** B42.20's counted per-file lock references. The worker acquires AND releases the same thread-owned lock. */
final class GameChunkAccess implements OwnedChunkWrites.Access {
    private final Method acquire, release, vanillaWrite, filename, noSave, coreInstance;
    private final Field filenames, rw;
    GameChunkAccess(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> chunk = Class.forName("zombie.iso.IsoChunk", false, loader);
        Class<?> lock = Class.forName("zombie.iso.IsoChunk$ChunkLock", false, loader);
        acquire = chunk.getDeclaredMethod("acquireLock", int.class, int.class);
        release = chunk.getDeclaredMethod("releaseLock", lock);
        rw = lock.getDeclaredField("rw");
        vanillaWrite = chunk.getMethod("SafeWrite", int.class, int.class, ByteBuffer.class);
        Class<?> names = Class.forName("zombie.ChunkMapFilenames", false, loader);
        filenames = names.getField("instance"); filename = names.getMethod("getFilename", int.class, int.class);
        Class<?> core = Class.forName("zombie.core.Core", false, loader);
        coreInstance = core.getMethod("getInstance"); noSave = core.getMethod("isNoSave");
        if (rw.getType() != ReentrantReadWriteLock.class || !acquire.trySetAccessible()
                || !release.trySetAccessible() || !rw.trySetAccessible()) throw new IllegalAccessException("Unsupported chunk lock contract");
    }
    public File destination(int x, int y) throws Exception {
        if ((boolean)invoke(noSave, invoke(coreInstance, null))) return null;
        return (File)invoke(filename, filenames.get(null), x, y);
    }
    public OwnedChunkWrites.LockReference reserve(int x, int y) throws Exception {
        Object reference = invoke(acquire, null, x, y);
        Lock write;
        try { write = ((ReentrantReadWriteLock)rw.get(reference)).writeLock(); }
        catch (Exception failure) { invoke(release, null, reference); throw failure; }
        return new OwnedChunkWrites.LockReference() {
            public Lock writeLock() { return write; }
            public void close() throws Exception { invoke(release, null, reference); }
        };
    }
    public void synchronous(int x, int y, ByteBuffer bytes) throws Exception { invoke(vanillaWrite, null, x, y, bytes); }
    private static Object invoke(Method method, Object receiver, Object... args) throws Exception {
        try { return method.invoke(receiver, args); }
        catch (InvocationTargetException failure) {
            if (failure.getCause() instanceof Exception exception) throw exception;
            throw (Error)failure.getCause();
        }
    }
}
