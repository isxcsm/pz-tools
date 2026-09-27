package pztools.extensions.api.internal;

import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.jar.*;

/** Bounded closed archive snapshot: the bytes hashed are exactly the bytes loaded. Not a sandbox. */
public final class ClassArchive {
    private ClassArchive() { }
    public static Snapshot read(Path path) throws IOException {
        if (!path.isAbsolute() || Files.isSymbolicLink(path)) throw new IOException("Invalid module path");
        byte[] archive;
        try (var input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
            archive = input.readNBytes(16 * 1024 * 1024 + 1);
        }
        if (archive.length > 16 * 1024 * 1024) throw new IOException("Oversized module archive");
        try { return new Snapshot(archive, HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(archive))); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    public static ClassLoader open(Path path, String namespace, ClassLoader parent) throws IOException {
        return read(path).loader(namespace, parent, true);
    }
    public static final class Snapshot {
        private final byte[] bytes;
        private final String digest;
        private Snapshot(byte[] bytes, String digest) { this.bytes = bytes; this.digest = digest; }
        public String digest() { return digest; }
        public String attribute(String name) throws IOException {
            // Valid ZIP editors may place the manifest after class entries. Do not mistake that for an ABI mismatch.
            try (var zip = new java.util.zip.ZipInputStream(new ByteArrayInputStream(bytes))) {
                int entries = 0;
                for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                    if (++entries > 2048) throw new IOException("Too many archive entries");
                    if (!entry.getName().equals("META-INF/MANIFEST.MF")) continue;
                    byte[] manifest = zip.readNBytes(65537);
                    if (manifest.length > 65536) throw new IOException("Oversized module manifest");
                    return new Manifest(new ByteArrayInputStream(manifest)).getMainAttributes().getValue(name);
                }
                return null;
            }
        }
        public void require(String name, String expected) throws IOException {
            if (!expected.equals(attribute(name))) throw new IOException("Incompatible archive contract: " + name);
        }
        public ClassLoader loader(String namespace, ClassLoader parent, boolean strict) throws IOException {
            String prefix = namespace.replace('.', '/') + "/";
            var classes = new HashMap<String, byte[]>(); int total = 0;
            try (var zip = new JarInputStream(new ByteArrayInputStream(bytes))) {
                for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                    if (entry.isDirectory()) continue;
                    String name = entry.getName();
                    if (name.startsWith("META-INF/") || name.startsWith("pztools/extensions/api/")) continue;
                    if (!name.startsWith(prefix)) {
                        if (strict) throw new IOException("Unexpected module entry: " + name);
                        continue;
                    }
                    if (!name.endsWith(".class") || name.contains("..")) throw new IOException("Invalid class entry");
                    byte[] code = zip.readNBytes(2 * 1024 * 1024 + 1); total = Math.addExact(total, code.length);
                    if (code.length > 2 * 1024 * 1024 || total > 32 * 1024 * 1024 || classes.size() >= 1024)
                        throw new IOException("Oversized module classes");
                    if (classes.putIfAbsent(name.substring(0, name.length()-6).replace('/', '.'), code) != null)
                        throw new IOException("Duplicate module class");
                }
            }
            if (classes.isEmpty()) throw new IOException("Empty module archive");
            return new ClassLoader(parent) {
                @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                    if (!name.startsWith(namespace + ".")) return super.loadClass(name, resolve);
                    synchronized (getClassLoadingLock(name)) {
                        Class<?> type = findLoadedClass(name);
                        if (type == null) {
                            byte[] code = classes.get(name);
                            if (code == null) throw new ClassNotFoundException(name);
                            type = defineClass(name, code, 0, code.length);
                        }
                        if (resolve) resolveClass(type);
                        return type;
                    }
                }
            };
        }
    }
}
