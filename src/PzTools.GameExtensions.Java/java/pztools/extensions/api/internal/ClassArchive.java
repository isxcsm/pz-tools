package pztools.extensions.api.internal;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.ZipInputStream;

/** Closed, bounded archive snapshot. This isolates dependencies, not untrusted code. */
public final class ClassArchive {
    private ClassArchive() { }
    public static ClassLoader open(Path path, String namespace, ClassLoader parent) throws IOException {
        if (!path.isAbsolute() || Files.isSymbolicLink(path)) throw new IOException("Invalid module path");
        byte[] archive;
        try (var input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
            archive = input.readNBytes(16 * 1024 * 1024 + 1);
        }
        if (archive.length > 16 * 1024 * 1024) throw new IOException("Oversized module archive");
        String prefix = namespace.replace('.', '/') + "/";
        var classes = new HashMap<String, byte[]>();
        int total = 0;
        try (var zip = new ZipInputStream(new ByteArrayInputStream(archive))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                if (entry.isDirectory()) continue;
                String name = entry.getName();
                if (name.startsWith("META-INF/")) continue;
                // API classes are always provided by the stable parent loader.
                if (name.startsWith("pztools/extensions/api/")) continue;
                if (!name.startsWith(prefix) || !name.endsWith(".class") || name.contains(".."))
                    throw new IOException("Unexpected module entry: " + name);
                byte[] bytes = zip.readNBytes(2 * 1024 * 1024 + 1);
                total = Math.addExact(total, bytes.length);
                if (bytes.length > 2 * 1024 * 1024 || total > 32 * 1024 * 1024 || classes.size() >= 1024)
                    throw new IOException("Oversized module classes");
                String className = name.substring(0, name.length() - 6).replace('/', '.');
                if (classes.putIfAbsent(className, bytes) != null) throw new IOException("Duplicate module class");
            }
        }
        if (classes.isEmpty()) throw new IOException("Empty module archive");
        return new ClassLoader(parent) {
            @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (!name.startsWith(namespace + ".")) return super.loadClass(name, resolve);
                synchronized (getClassLoadingLock(name)) {
                    Class<?> type = findLoadedClass(name);
                    if (type == null) {
                        byte[] bytes = classes.get(name);
                        if (bytes == null) throw new ClassNotFoundException(name);
                        type = defineClass(name, bytes, 0, bytes.length);
                    }
                    if (resolve) resolveClass(type);
                    return type;
                }
            }
        };
    }
}
