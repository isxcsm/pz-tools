package pztools.extensions.seamless.b4220;

import java.lang.reflect.*;
import java.util.Queue;

/** Advisory preflight, not a lock: vanilla checks still handle a worker starting after this observation. */
final class CaptureReadiness {
    private final Field chunks, saving, queue, collision, nativeThread, nativeSaving, streamer, databaseThread;
    CaptureReadiness(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> type = Class.forName("zombie.iso.ChunkSaveWorker", false, loader);
        chunks = type.getField("instance"); saving = type.getField("saving"); queue = type.getField("toSaveQueue");
        Class<?> streamType = Class.forName("zombie.iso.WorldStreamer", false, loader);
        streamer = streamType.getField("instance"); databaseThread = streamType.getField("worldStreamer");
        if (!Thread.class.isAssignableFrom(databaseThread.getType())) throw new IllegalStateException("Unsupported database worker");
        Class<?> nativeType = Class.forName("zombie.MapCollisionData", false, loader);
        collision = nativeType.getDeclaredField("instance"); nativeThread = nativeType.getDeclaredField("thread");
        nativeSaving = nativeThread.getType().getDeclaredField("save");
        if (saving.getType() != boolean.class || !Queue.class.isAssignableFrom(queue.getType())
                || nativeSaving.getType() != boolean.class || !Modifier.isVolatile(nativeSaving.getModifiers())
                || !nativeThread.trySetAccessible() || !nativeSaving.trySetAccessible())
            throw new IllegalStateException("Unsupported save readiness layout");
    }
    Thread databaseWorker() throws IllegalAccessException {
        Object owner = streamer.get(null);
        return owner == null ? null : (Thread)databaseThread.get(owner);
    }
    boolean ready() throws IllegalAccessException {
        Thread database = databaseWorker();
        if (database == null || !database.isAlive()) return false;
        Object worker = chunks.get(null);
        if (worker == null || saving.getBoolean(worker) || !((Queue<?>)queue.get(worker)).isEmpty()) return false;
        Object owner = collision.get(null);
        if (owner == null) return false;
        Object thread = nativeThread.get(owner);
        return thread == null || !nativeSaving.getBoolean(thread);
    }
}