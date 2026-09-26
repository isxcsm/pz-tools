import pztools.extensions.seamless.b4220.SaveBytecode;
import java.lang.classfile.*;
import java.net.URLClassLoader;
import java.nio.file.Path;
import java.util.jar.JarFile;

/** Optional read-only local structural verification. Never launches a game or runs static initializers. */
public final class VerifyInstalledSaveBytecode {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Expected installed game JAR path");
        Path path = Path.of(args[0]).toAbsolutePath();
        try (var jar = new JarFile(path.toFile());
             var loader = new URLClassLoader(new java.net.URL[] { path.toUri().toURL() }, VerifyInstalledSaveBytecode.class.getClassLoader())) {
            var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
            for (String name : new String[] { "zombie/GameWindow", "zombie/savefile/PlayerDB",
                    "zombie/vehicles/VehiclesDB2", "zombie/core/logger/ExceptionLogger" }) {
                byte[] original;
                try (var input = jar.getInputStream(jar.getJarEntry(name + ".class"))) { original = input.readAllBytes(); }
                byte[] transformed = SaveBytecode.transform(name, original, loader);
                var errors = cf.verify(transformed);
                if (!errors.isEmpty()) throw new AssertionError(name + ": " + errors);
                System.out.println("VERIFIED (not executed): " + name);
            }
        }
    }
}
