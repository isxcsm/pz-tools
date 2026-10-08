package pztools.bridge.runtime;

import java.lang.classfile.ClassFile;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.nio.file.*;
import java.util.jar.*;

/**
 * The extension API's own jar (ApiHost): loaded and started once, kept while its digest stays (another folder with the
 * same bytes, as after a payload switch or a move, gives the same API without starting it again), replaced and started
 * anew when the jar changed, and refused when it names another bootstrap API than the game loaded.
 */
final class ApiHostTest {
    private static final String STARTED = "pztools.apitest.started", BOOTSTRAP = "pztools.bridge.bootstrap.api";

    private ApiHostTest() { }

    static void run() throws Exception {
        String bootstrapWas = System.getProperty(BOOTSTRAP);
        System.setProperty(BOOTSTRAP, "12");
        Path folder = Files.createTempDirectory("pztools-api-host");
        try {
            Path first = jar(folder.resolve("one").resolve(ApiHost.JAR), "one", "12");
            var api = ApiHost.current(first);
            check("one".equals(System.getProperty(STARTED)), "A new API jar was not started");
            try {
                api.frame(ApiHostTest.class.getClassLoader());
                api.writeStatus(folder);
            } catch (Throwable failure) { throw new AssertionError("The API's frame or status failed", failure); }
            System.clearProperty(STARTED);
            check(ApiHost.current(first) == api, "An unchanged jar was read again");

            // The same bytes elsewhere: the API kept, not started again.
            Path copy = folder.resolve("copy").resolve(ApiHost.JAR);
            Files.createDirectories(copy.getParent());
            Files.copy(first, copy);
            var kept = ApiHost.current(copy);
            check(kept.type() == api.type() && System.getProperty(STARTED) == null, "The same API jar loaded a new API");

            // A changed jar: a new API, started.
            Path second = jar(folder.resolve("two").resolve(ApiHost.JAR), "two", "12");
            var next = ApiHost.current(second);
            check(next.type() != api.type() && "two".equals(System.getProperty(STARTED)), "A changed API jar was not loaded");

            // Built for another bootstrap: refused, and the running API stays.
            System.clearProperty(STARTED);
            Path other = jar(folder.resolve("other").resolve(ApiHost.JAR), "other", "11");
            try {
                ApiHost.current(other);
                check(false, "An API jar for another bootstrap was loaded");
            } catch (java.io.IOException refused) { }
            check(System.getProperty(STARTED) == null && ApiHost.current(second).type() == next.type(),
                "A refused jar replaced the running API");
        } finally {
            try (var files = Files.walk(folder)) {
                for (Path file : files.sorted(java.util.Comparator.reverseOrder()).toList()) Files.deleteIfExists(file);
            }
            System.clearProperty(STARTED);
            if (bootstrapWas == null) System.clearProperty(BOOTSTRAP); else System.setProperty(BOOTSTRAP, bootstrapWas);
        }
        System.out.println("PASS: the extension API's jar loads and starts once, is kept by its digest across folders,"
            + " is replaced when it changes, and is refused for another bootstrap");
    }

    /** An API jar whose GameApi's start() records its label, and whose frame and status do nothing. */
    private static Path jar(Path path, String label, String bootstrapApi) throws Exception {
        byte[] code = ClassFile.of().build(ClassDesc.of("pztools.api.GameApi"), type -> {
            type.withFlags(ClassFile.ACC_PUBLIC | ClassFile.ACC_FINAL).withSuperclass(ConstantDescs.CD_Object);
            int flags = ClassFile.ACC_PUBLIC | ClassFile.ACC_STATIC;
            type.withMethodBody("start", MethodTypeDesc.of(ConstantDescs.CD_void), flags, body -> body
                .ldc(STARTED).ldc(label)
                .invokestatic(ClassDesc.of("java.lang.System"), "setProperty",
                    MethodTypeDesc.of(ConstantDescs.CD_String, ConstantDescs.CD_String, ConstantDescs.CD_String))
                .pop().return_());
            type.withMethodBody("frame", MethodTypeDesc.of(ConstantDescs.CD_void, ClassDesc.of("java.lang.ClassLoader")),
                flags, body -> body.return_());
            type.withMethodBody("writeStatus", MethodTypeDesc.of(ConstantDescs.CD_void, ClassDesc.of("java.nio.file.Path")),
                flags, body -> body.return_());
        });
        var manifest = new Manifest();
        manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
        manifest.getMainAttributes().putValue("PzTools-Bootstrap-Api", bootstrapApi);
        Files.createDirectories(path.getParent());
        try (var out = new JarOutputStream(Files.newOutputStream(path), manifest)) {
            out.putNextEntry(new JarEntry("pztools/api/GameApi.class"));
            out.write(code);
            out.closeEntry();
        }
        return path;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
