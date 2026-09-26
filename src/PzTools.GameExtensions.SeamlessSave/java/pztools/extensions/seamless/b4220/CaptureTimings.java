package pztools.extensions.seamless.b4220;

import java.lang.invoke.*;
import java.nio.ByteBuffer;

/** One save's aggregate durations, only on private calls. No frame poller, history or file I/O. */
final class CaptureTimings {
    private long started, chunk, handoff, animal, collision;
    private int chunks;
    private boolean active;
    void start() { chunk = handoff = animal = collision = 0; chunks = 0; active = true; started = System.nanoTime(); }
    String finish() {
        long total = System.nanoTime() - started;
        active = false;
        return "chunkCount=" + chunks + "; chunkBodyUs=" + Math.max(0, chunk - handoff) / 1000
            + "; chunkHandoffUs=" + handoff / 1000 + "; animalSaveUs=" + animal / 1000
            + "; collisionSaveUs=" + collision / 1000
            + "; otherCaptureUs=" + Math.max(0, total - chunk - animal - collision) / 1000;
    }
    MethodHandle chunk(MethodHandle target) throws ReflectiveOperationException {
        var call = new ChunkCall(target.asType(MethodType.methodType(void.class, Object.class, boolean.class)));
        return MethodHandles.lookup().findVirtual(ChunkCall.class, "run",
            MethodType.methodType(void.class, Object.class, boolean.class)).bindTo(call).asType(target.type());
    }
    MethodHandle write(MethodHandle target) throws ReflectiveOperationException {
        var call = new WriteCall(target);
        return MethodHandles.lookup().findVirtual(WriteCall.class, "run",
            MethodType.methodType(void.class, int.class, int.class, ByteBuffer.class)).bindTo(call);
    }
    MethodHandle nativeCall(MethodHandle target, boolean animals) throws ReflectiveOperationException {
        var call = new NativeCall(target.asType(MethodType.methodType(void.class, Object.class)), animals);
        return MethodHandles.lookup().findVirtual(NativeCall.class, "run",
            MethodType.methodType(void.class, Object.class)).bindTo(call).asType(target.type());
    }
    private final class ChunkCall {
        final MethodHandle target;
        ChunkCall(MethodHandle target) { this.target = target; }
        void run(Object receiver, boolean full) throws Throwable {
            long before = active ? System.nanoTime() : 0;
            try { target.invokeExact(receiver, full); }
            finally { if (before != 0) { chunk += System.nanoTime() - before; chunks++; } }
        }
    }
    private final class WriteCall {
        final MethodHandle target;
        WriteCall(MethodHandle target) { this.target = target; }
        void run(int x, int y, ByteBuffer bytes) throws Throwable {
            long before = active ? System.nanoTime() : 0;
            try { target.invokeExact(x, y, bytes); }
            finally { if (before != 0) handoff += System.nanoTime() - before; }
        }
    }
    private final class NativeCall {
        final MethodHandle target;
        final boolean animals;
        NativeCall(MethodHandle target, boolean animals) { this.target = target; this.animals = animals; }
        void run(Object receiver) throws Throwable {
            long before = active ? System.nanoTime() : 0;
            try { target.invokeExact(receiver); }
            finally {
                if (before != 0) {
                    long elapsed = System.nanoTime() - before;
                    if (animals) animal += elapsed; else collision += elapsed;
                }
            }
        }
    }
}
