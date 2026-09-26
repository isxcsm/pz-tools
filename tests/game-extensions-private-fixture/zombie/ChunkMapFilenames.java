package zombie;
import java.io.File;
public final class ChunkMapFilenames {
    public static final ChunkMapFilenames instance = new ChunkMapFilenames();
    public static File root;
    public File getFilename(int x, int y) { return new File(root, x + "_" + y + ".bin"); }
}
