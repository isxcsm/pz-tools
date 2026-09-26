package pztools.extensions.seamless.b4220;

import java.lang.reflect.*;
import java.util.Queue;

/** Advisory preflight, not a lock: vanilla checks still handle a worker starting after this observation. */
final class CaptureReadiness implements FrameSavePlan.Ready {
    static final int DATABASE_UNAVAILABLE = 1, CHUNK_WORKER_UNAVAILABLE = 2, CHUNK_SAVING = 4,
        QUEUED_CHUNKS = 8, NATIVE_UNAVAILABLE = 16, NATIVE_SAVING = 32, UNKNOWN = 64;
    static final int REASON_COUNT = 7;
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
    boolean ready() throws IllegalAccessException { return blockers() == 0; }
    @Override public boolean get() throws IllegalAccessException { return ready(); }
    @Override public int blockers(int stage) throws IllegalAccessException { return blockers(); }
    int blockers() throws IllegalAccessException {
        int reasons = 0;
        Thread database = databaseWorker();
        if (database == null || !database.isAlive()) reasons |= DATABASE_UNAVAILABLE;
        Object worker = chunks.get(null);
        if (worker == null) reasons |= CHUNK_WORKER_UNAVAILABLE;
        else {
            if (saving.getBoolean(worker)) reasons |= CHUNK_SAVING;
            Queue<?> pending = (Queue<?>)queue.get(worker);
            if (pending == null) reasons |= CHUNK_WORKER_UNAVAILABLE;
            else if (!pending.isEmpty()) reasons |= QUEUED_CHUNKS;
        }
        Object owner = collision.get(null);
        if (owner == null) reasons |= NATIVE_UNAVAILABLE;
        else {
            Object thread = nativeThread.get(owner);
            // Preserve the original advisory policy: an absent optional native thread is ready.
            if (thread != null && nativeSaving.getBoolean(thread)) reasons |= NATIVE_SAVING;
        }
        return reasons;
    }
}
