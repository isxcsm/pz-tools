package pzext.api;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.zip.CRC32;

/**
 * What the map facts that read the whole map ({@code zones.clusters}, {@code zombies.dense}) keep on disk, so that a game does not walk
 * the meta grid again for a map set it has seen: one file for each question, in {@code <the game's cache folder>/pzext/maps}.
 *
 * <p>A file holds the stamp of the map set it was made for and the answer. The stamp is the maps the world loads (the folders
 * {@code IsoLot.MapFiles} lists, in order, which is where the game keeps them), with for each folder a cheap fingerprint of the data
 * the answer comes from (its {@code .lotheader} files' count, total size and newest time for the zombie intensity, its
 * {@code objects.lua}'s size and time for the zones), and whatever else the caller adds. A file whose stamp differs, or that is
 * broken, old (another version byte) or cut short, is ignored and written again. A file is written to a temporary one and moved
 * into place, so a game that stops half way leaves no broken file; two games at once keep whichever finished last.
 *
 * <p>The disk is an aid: every failure here (a folder that cannot be written, a file that cannot be read) is answered as a miss,
 * and the caller works the answer out and goes on.
 */
final class MapCache {
    /** The file format; a file of another version is not read. */
    private static final byte VERSION = 1;
    private static final int MAGIC = 0x505A4D43;
    /** The largest file read: a bound against a file that is not ours. */
    private static final long MAX_FILE = 256L << 20;

    // IsoLot.MapFiles (static); MapFiles.mapDirectoryName and mapDirectoryAbsolutePath; ZomboidFileSystem.instance.getCacheDir().
    private final MethodHandle files, name, folder, cacheDir;
    private final Object system;

    /** The map set a world loads: the names of its folders and the stamp that tells whether their data is the same. */
    record Maps(String names, String stamp) { }

    MapCache(ClassLoader loader) throws ReflectiveOperationException {
        var lookup = MethodHandles.publicLookup();
        Class<?> lot = Game.type(loader, "zombie.iso.IsoLot"), map = Game.type(loader, "zombie.iso.MapFiles");
        files = lookup.unreflectGetter(lot.getField("MapFiles")).asType(MethodType.methodType(ArrayList.class));
        MethodType text = MethodType.methodType(String.class, Object.class);
        name = lookup.unreflectGetter(map.getField("mapDirectoryName")).asType(text);
        folder = lookup.unreflectGetter(map.getField("mapDirectoryAbsolutePath")).asType(text);
        Class<?> filesystem = Game.type(loader, "zombie.ZomboidFileSystem");
        system = filesystem.getField("instance").get(null);
        cacheDir = Game.exact(filesystem.getMethod("getCacheDir"), MethodType.methodType(String.class, Object.class));
    }

    /**
     * The maps the world loads now, fingerprinted by the zones' file ({@code zones}) or by the zombie intensity's files; null when
     * the game lists none or one cannot be read, which gives no disk cache. Reads the folders' listings: a caller keeps what it gets.
     */
    Maps maps(boolean zones) {
        try {
            ArrayList<?> list = (ArrayList<?>)files.invokeExact();
            if (list == null || list.isEmpty()) return null;
            var names = new StringBuilder();
            var stamp = new StringBuilder();
            for (Object map : list) {
                String mapName = (String)name.invokeExact(map), path = (String)folder.invokeExact(map);
                if (mapName == null || path == null) return null;
                Path directory = Path.of(path);
                if (!Files.isDirectory(directory)) return null;
                names.append(mapName).append('\n');
                stamp.append(mapName).append(':');
                if (zones) {
                    Path objects = directory.resolve("objects.lua");
                    if (Files.isRegularFile(objects)) stamp.append(Files.size(objects)).append('@').append(Files.getLastModifiedTime(objects).toMillis());
                    else stamp.append("none");
                } else {
                    long count = 0, size = 0, newest = 0;
                    try (DirectoryStream<Path> headers = Files.newDirectoryStream(directory, "*.lotheader")) {
                        for (Path header : headers) {
                            count++;
                            size += Files.size(header);
                            newest = Math.max(newest, Files.getLastModifiedTime(header).toMillis());
                        }
                    }
                    stamp.append(count).append(',').append(size).append('@').append(newest);
                }
                stamp.append('\n');
            }
            return new Maps(names.toString(), stamp.toString());
        } catch (Throwable failure) {
            if (failure instanceof Error error && !(error instanceof LinkageError)) throw error;
            return null;
        }
    }

    /** The answer kept for the question {@code question} (which names what is asked) under the stamp, or null. */
    byte[] read(String question, String stamp) {
        try {
            Path file = file(question);
            if (file == null || !Files.isRegularFile(file) || Files.size(file) > MAX_FILE) return null;
            try (var in = new DataInputStream(new ByteArrayInputStream(Files.readAllBytes(file)))) {
                if (in.readInt() != MAGIC || in.readByte() != VERSION || !in.readUTF().equals(stamp)) return null;
                byte[] data = new byte[in.readInt()];
                long crc = in.readLong();
                in.readFully(data);
                if (in.read() != -1) return null;
                var check = new CRC32();
                check.update(data);
                return check.getValue() == crc ? data : null;
            }
        } catch (IOException | RuntimeException unreadable) {
            return null;
        } catch (Throwable failure) {
            if (failure instanceof Error error && !(error instanceof LinkageError)) throw error;
            return null;
        }
    }

    /** Keeps the answer for the question under the stamp; a failure leaves the disk as it was. */
    void write(String question, String stamp, byte[] data) {
        Path temporary = null;
        try {
            Path file = file(question);
            if (file == null) return;
            var bytes = new ByteArrayOutputStream(data.length + stamp.length() + 32);
            try (var out = new DataOutputStream(bytes)) {
                out.writeInt(MAGIC);
                out.writeByte(VERSION);
                out.writeUTF(stamp);
                out.writeInt(data.length);
                var check = new CRC32();
                check.update(data);
                out.writeLong(check.getValue());
                out.write(data);
            }
            Files.createDirectories(file.getParent());
            temporary = Files.createTempFile(file.getParent(), "map", ".tmp");
            Files.write(temporary, bytes.toByteArray());
            try { Files.move(temporary, file, StandardCopyOption.ATOMIC_MOVE); }
            catch (AtomicMoveNotSupportedException plain) { Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING); }
            temporary = null;
        } catch (IOException | RuntimeException unwritable) {
            // A disk that cannot be written is no reason to fail a question.
        } catch (Throwable failure) {
            if (failure instanceof Error error && !(error instanceof LinkageError)) throw error;
        } finally {
            if (temporary != null) {
                try { Files.deleteIfExists(temporary); }
                catch (IOException stays) { }
            }
        }
    }

    /** The file of a question: its name is a hash of the question, so a changed map set rewrites the one file. */
    private Path file(String question) throws Throwable {
        String root = (String)cacheDir.invokeExact(system);
        if (root == null || root.isEmpty()) return null;
        byte[] hash = MessageDigest.getInstance("SHA-256").digest(question.getBytes(StandardCharsets.UTF_8));
        return Path.of(root, "pzext", "maps", HexFormat.of().formatHex(hash, 0, 16) + ".bin");
    }
}
