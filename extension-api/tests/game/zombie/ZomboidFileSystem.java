package zombie;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Synthetic: the game's file system, which names the file a path of the game's ({@code media/...}) is, the game's own or a mod's.
 * The files there are, by their path in lower case, are what the test puts in {@link #FILES}.
 */
public final class ZomboidFileSystem {
    public static final ZomboidFileSystem instance = new ZomboidFileSystem();
    /** The absolute file of each path there is, by the path in lower case. */
    public static final Map<String, String> FILES = new HashMap<>();

    /** The current save's folder, as a test sets it. */
    public static java.io.File save;

    /** The folder the game keeps its caches in, as a test sets it. */
    public static String cacheFolder;

    private ZomboidFileSystem() { }

    /** As the game's: the folder it keeps its caches (saves, logs, mods' files) in. */
    public String getCacheDir() { return cacheFolder; }

    /** A file of the current save, as the game's. */
    public java.io.File getFileInCurrentSave(String name) { return new java.io.File(save, name); }

    /** The file of a path; the very string given for a path there is none for, as the game's. */
    public String getString(String path) {
        String file = FILES.get(path.toLowerCase(Locale.ENGLISH));
        return file != null ? file : path;
    }
}
