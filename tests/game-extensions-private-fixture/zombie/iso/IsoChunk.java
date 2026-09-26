package zombie.iso;
import java.io.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.locks.*;
public class IsoChunk {
    private static final Object WriteLock = new Object();
    private static final Map<String, ChunkLock> locks = new HashMap<>();
    private static int serial;
    private int x, y;
    private static ByteBuffer scratch = ByteBuffer.allocate(4);
    private static int serialize() { return ++serial; }
    public void Save(boolean full) throws IOException {
        synchronized (WriteLock) {
            scratch.clear(); scratch.putInt(serialize());
            if (x < 0) SafeWrite(x, y, scratch); else SafeWrite(x, y, scratch);
        }
    }
    private static synchronized ChunkLock acquireLock(int x, int y) {
        var lock = locks.computeIfAbsent(x + ":" + y, ignored -> new ChunkLock()); lock.count++; return lock;
    }
    private static synchronized void releaseLock(ChunkLock lock) { lock.count--; }
    public static synchronized int references() { return locks.values().stream().mapToInt(l -> l.count).sum(); }
    static final class ChunkLock { public final ReentrantReadWriteLock rw = new ReentrantReadWriteLock(true); int count; }
    public static void SafeWrite(int x, int y, ByteBuffer bytes) throws IOException {
        ChunkLock reference = acquireLock(x, y); var lock = reference.rw.writeLock(); lock.lock();
        try (var out = new FileOutputStream(zombie.ChunkMapFilenames.instance.getFilename(x, y))) {
            out.write(bytes.array(), 0, bytes.position());
        } finally { lock.unlock(); releaseLock(reference); }
    }
    public static ByteBuffer SafeRead(int x, int y, ByteBuffer bytes) throws IOException {
        ChunkLock reference = acquireLock(x, y); var lock = reference.rw.readLock(); lock.lock();
        try { return ByteBuffer.wrap(Files.readAllBytes(zombie.ChunkMapFilenames.instance.getFilename(x,y).toPath())); }
        finally { lock.unlock(); releaseLock(reference); }
    }
    public static final class Modded extends IsoChunk {
        public static int overrides;
        @Override public void Save(boolean full) throws IOException { overrides++; SafeWrite(0, 0, ByteBuffer.allocate(4).putInt(900)); }
    }
}
