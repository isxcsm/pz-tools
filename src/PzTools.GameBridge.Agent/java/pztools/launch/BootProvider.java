package pztools.launch;

import java.net.URI;
import java.nio.channels.SeekableByteChannel;
import java.nio.file.AccessMode;
import java.nio.file.CopyOption;
import java.nio.file.DirectoryStream;
import java.nio.file.FileStore;
import java.nio.file.FileSystem;
import java.nio.file.FileSystemNotFoundException;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.FileAttribute;
import java.nio.file.attribute.FileAttributeView;
import java.nio.file.spi.FileSystemProvider;
import java.util.Map;
import java.util.Set;

/**
 * How the game reaches the {@link StartupLoader} without a changed game class (docs/design/startup-loader.md). The JDK
 * creates the installed file system providers, the ones named in {@code META-INF/services} on the class path, once,
 * the first time anything asks for one; the game does that early in its main method, when it zips its last logs. The
 * install gives the game's folder {@code pztools/pztools-launch.jar}, whose services list names this class, and lists the jar
 * in the launcher file's class path; where the launcher file is plain (the game's folder still on the class path) the
 * frozen shim in the game's folder ({@code pztools.startup.BootProvider}) loads the same jar when it is not on the class
 * path. Creating the provider starts the loader; it serves no files of its own.
 *
 * <p>Nothing may escape the constructor: a provider that fails to be created leaves the JDK unable to list file system
 * providers for the rest of the run, and the game's zip files with it. It must also not ask for a file system
 * provider itself (the JDK would call that circular), and it waits for no other thread, which might be asking.
 * Uses java.base alone.
 */
public final class BootProvider extends FileSystemProvider {
    public BootProvider() {
        try { StartupLoader.start(); } catch (Throwable ignored) { }
    }

    @Override public String getScheme() { return "pztools-startup"; }

    private static UnsupportedOperationException none() {
        return new UnsupportedOperationException("pztools-startup serves no files");
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
