import java.io.*;
import java.nio.ByteBuffer;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/** Game-free analogue of the pinned adapter's locked SafeWrite/SafeRead blocks. */
public final class ChunkIoTemplate {
    public static File root;
    public static int writeFinalizers, readFinalizers;
    public static final Sanity sanityCheck = new Sanity();
    private static final ReentrantReadWriteLock locks = new ReentrantReadWriteLock();
    public static final class Sanity {
        public void beginSaveFile(String file) { }
        public void endSaveFile() { writeFinalizers++; }
        public void beginLoadFile(String file) { }
        public void endLoadFile(String file) { readFinalizers++; }
    }
    public static void SafeWrite(int x, int y, ByteBuffer buffer) throws IOException {
        var lock = locks.writeLock(); lock.lock();
        try {
            File file = new File(root, x + "_" + y + ".bin");
            sanityCheck.beginSaveFile(file.getAbsolutePath());
            try {
                try (FileOutputStream output = new FileOutputStream(file)) {
                    output.getChannel().truncate(0);
                    output.write(buffer.array(), 0, buffer.position());
                }
            } finally { sanityCheck.endSaveFile(); }
        } finally { lock.unlock(); }
    }
    public static ByteBuffer SafeRead(int x, int y, ByteBuffer buffer) throws IOException {
        var lock = locks.readLock(); lock.lock();
        try {
            File file = new File(root, x + "_" + y + ".bin");
            sanityCheck.beginLoadFile(file.getAbsolutePath());
            try {
                try (FileInputStream input = new FileInputStream(file)) {
                    buffer.clear(); buffer.put(input.readAllBytes()); buffer.flip();
                }
            } finally { sanityCheck.endLoadFile(file.getAbsolutePath()); }
        } finally { lock.unlock(); }
        return buffer;
    }
}