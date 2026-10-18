package zombie.iso;

/** Synthetic: one map folder the world loads: its name, and the folder on disk. */
public final class MapFiles {
    public final String mapDirectoryName;
    public final String mapDirectoryAbsolutePath;

    public MapFiles(String name, String absolutePath) {
        mapDirectoryName = name;
        mapDirectoryAbsolutePath = absolutePath;
    }
}
