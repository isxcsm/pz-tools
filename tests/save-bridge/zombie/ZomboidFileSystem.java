package zombie;
public final class ZomboidFileSystem {
    public static final ZomboidFileSystem instance = new ZomboidFileSystem();
    public static String path;
    public String getCurrentSaveDir() { return path; }
}
