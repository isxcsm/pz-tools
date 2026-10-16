package pzext.loader;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.net.URI;
import java.net.URL;
import java.nio.channels.SeekableByteChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AccessMode;
import java.nio.file.CopyOption;
import java.nio.file.DirectoryStream;
import java.nio.file.FileStore;
import java.nio.file.FileSystem;
import java.nio.file.FileSystemNotFoundException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.FileAttribute;
import java.nio.file.attribute.FileAttributeView;
import java.nio.file.spi.FileSystemProvider;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * THE FROZEN SHIM. This class and its nested {@code BootProvider$Jar} are the only loose class files PZ Extension API puts
 * in the game's folder, and their bytes must never change from one release to the next (docs/loader.md): other tools copy
 * the game folder's loose class files into a jar of their own (PZ Optimize's AOT step) and rebuild that jar whenever the
 * set or the bytes of those files differ, which a running game, holding the jar open, cannot let them do. A test pins the
 * SHA-256 of both built classes; a change here is a deliberate decision and a new pin.
 *
 * <p>All the real work is in {@code pzext/pzext-launch.jar}. When the JDK creates this provider from the game folder's
 * services list (the folder is still on the class path) and the jar is not on the class path as well, the shim reads the
 * jar once, checks its SHA-256 against {@code sha256} in {@code pzext/loader/install.properties} (what the install wrote
 * there beside this class), and only then defines its classes, from the bytes it hashed, in a class loader of its own and
 * calls {@code pzext.launch.Loader.start()}, which keeps the one-boot-a-process guard, checks the install folder and
 * heals the launcher file. With the jar on the class path its own provider starts the loader and this one does nothing; a
 * copy of this class inside another tool's jar is not in the game's folder and does nothing either.
 *
 * <p>Nothing may escape: a provider that fails to be created leaves the JDK unable to list file system providers for the
 * rest of the run. A missing or damaged jar leaves a vanilla game and one line in the install folder's log. The shim asks for
 * no file system provider and waits for no thread. Uses java.base alone.
 */
public final class BootProvider extends FileSystemProvider {
    public BootProvider() {
        try { handOff(); } catch (Throwable ignored) { }
    }

    private static void handOff() throws Exception {
        // Found in a folder on the class path: the game's folder. A copy inside a jar is another tool's, and has no jar beside it.
        URL here = BootProvider.class.getResource("BootProvider.class");
        if (here == null || !"file".equals(here.getProtocol())) return;
        File game = new File(here.toURI()).getParentFile().getParentFile().getParentFile();
        // The jar is on the class path too: its own provider starts the loader.
        if (ClassLoader.getSystemClassLoader().getResource("pzext/launch/BootProvider.class") != null) return;
        Properties settings = new Properties();
        try (InputStream input = new FileInputStream(new File(game, "pzext/loader/install.properties"))) { settings.load(input); }
        String problem;
        try { problem = boot(new File(game, "pzext/pzext-launch.jar"), settings.getProperty("sha256", "")); }
        catch (Throwable failure) { problem = failure.toString(); }
        if (problem != null) note(settings.getProperty("root", ""), problem);
    }

    /** Null once the loader was started, else why not. */
    private static String boot(File file, String expected) throws Exception {
        if (!file.isFile()) return "the launch jar is missing";
        byte[] bytes = Files.readAllBytes(file.toPath());
        if (!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(expected))
            return "the launch jar does not match the install";
        Jar loader = new Jar(bytes, BootProvider.class.getClassLoader());
        Class.forName("pzext.launch.Loader", true, loader).getMethod("start").invoke(null);
        return null;
    }

    /** One line in the install folder's log, never through a link. */
    private static void note(String root, String line) {
        try {
            if (!new File(root).isAbsolute()) return;
            OpenOption[] options = { StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS };
            Files.write(new File(root, "loader.log").toPath(), (Instant.now() + " " + line + System.lineSeparator()).getBytes(StandardCharsets.UTF_8), options);
        } catch (Throwable ignored) { }
    }

    /** The jar's classes and resources from the bytes that were hashed; its own classes first. */
    static final class Jar extends ClassLoader {
        private final Map<String, byte[]> entries = new HashMap<>();

        Jar(byte[] bytes, ClassLoader parent) throws Exception {
            super(parent);
            try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(bytes))) {
                for (ZipEntry entry; (entry = zip.getNextEntry()) != null; )
                    if (!entry.isDirectory()) entries.put(entry.getName(), zip.readAllBytes());
            }
        }

        @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            synchronized (getClassLoadingLock(name)) {
                Class<?> found = findLoadedClass(name);
                byte[] bytes = entries.get(name.replace('.', '/') + ".class");
                if (found == null && bytes != null) found = defineClass(name, bytes, 0, bytes.length);
                if (found == null) return super.loadClass(name, resolve);
                if (resolve) resolveClass(found);
                return found;
            }
        }

        @Override public InputStream getResourceAsStream(String name) {
            byte[] bytes = entries.get(name);
            return bytes != null ? new ByteArrayInputStream(bytes) : super.getResourceAsStream(name);
        }
    }

    @Override public String getScheme() { return "pzext-loader"; }

    private static UnsupportedOperationException none() {
        return new UnsupportedOperationException("pzext-loader serves no files");
    }

    @Override public FileSystem newFileSystem(URI uri, Map<String, ?> env) { throw none(); }
    @Override public FileSystem getFileSystem(URI uri) { throw new FileSystemNotFoundException(); }
    @Override public Path getPath(URI uri) { throw new FileSystemNotFoundException(); }
    @Override public SeekableByteChannel newByteChannel(Path path, Set<? extends OpenOption> options, FileAttribute<?>... attrs) { throw none(); }
    @Override public DirectoryStream<Path> newDirectoryStream(Path dir, DirectoryStream.Filter<? super Path> filter) { throw none(); }
    @Override public void createDirectory(Path dir, FileAttribute<?>... attrs) { throw none(); }
    @Override public void delete(Path path) { throw none(); }
    @Override public void copy(Path source, Path target, CopyOption... options) { throw none(); }
    @Override public void move(Path source, Path target, CopyOption... options) { throw none(); }
    @Override public boolean isSameFile(Path path, Path path2) { throw none(); }
    @Override public boolean isHidden(Path path) { throw none(); }
    @Override public FileStore getFileStore(Path path) { throw none(); }
    @Override public void checkAccess(Path path, AccessMode... modes) { throw none(); }
    @Override public <V extends FileAttributeView> V getFileAttributeView(Path path, Class<V> type, LinkOption... options) { throw none(); }
    @Override public <A extends BasicFileAttributes> A readAttributes(Path path, Class<A> type, LinkOption... options) { throw none(); }
    @Override public Map<String, Object> readAttributes(Path path, String attributes, LinkOption... options) { throw none(); }
    @Override public void setAttribute(Path path, String attribute, Object value, LinkOption... options) { throw none(); }
}
