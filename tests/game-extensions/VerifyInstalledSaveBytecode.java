import pztools.extensions.seamless.b4220.*;
import java.lang.classfile.*;
import java.lang.invoke.*;
import java.net.URLClassLoader;
import java.nio.file.*;
import java.util.*;
import java.util.jar.JarFile;

/** Read-only installed-JAR validation. Defines private copies but NEVER invokes game saving/static initializers. */
public final class VerifyInstalledSaveBytecode {
    public static void main(String[] args) throws Throwable {
        if (args.length != 1) throw new IllegalArgumentException("Expected installed game JAR path");
        Path path = Path.of(args[0]).toAbsolutePath();
        try (var jar = new JarFile(path.toFile()); var loader = new URLClassLoader(new java.net.URL[]{path.toUri().toURL()}, VerifyInstalledSaveBytecode.class.getClassLoader())) {
            var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
            Map<String,byte[]> sources = new HashMap<>();
            for (var method : PrivateSaveGraph.SOURCES) {
                try (var in = jar.getInputStream(jar.getJarEntry(method.owner()+".class"))) { sources.put(method.owner(),in.readAllBytes()); }
                PrivateSaveGraph.methodFingerprint(loader,sources.get(method.owner()),method);
            }
            MethodHandle unused = MethodHandles.empty(MethodType.methodType(void.class,int.class,int.class,java.nio.ByteBuffer.class));
            PrivateSaveGraph.create(loader,sources,unused);
            System.out.println("VERIFIED (not executed): private save companions; no original save class replaced");
            for(String name : new String[]{"zombie/savefile/PlayerDB","zombie/vehicles/VehiclesDB2","zombie/core/logger/ExceptionLogger"}) {
                byte[] original;
                try(var in=jar.getInputStream(jar.getJarEntry(name+".class"))){original=in.readAllBytes();}
                byte[] observed=DatabaseObservationBytecode.transform(name,original,loader);
                if(!cf.verify(observed).isEmpty()) throw new AssertionError("Observer verification failed: "+name);
                System.out.println("VERIFIED (not executed): read-only observer "+name);
            }
            for(String type : new String[]{"CaptureReadiness","GameChunkAccess","OwnedNativeSave"}) {
                var constructor=Class.forName("pztools.extensions.seamless.b4220."+type).getDeclaredConstructor(ClassLoader.class);
                constructor.setAccessible(true); constructor.newInstance(loader);
            }
            System.out.println("VERIFIED (not initialized): original chunk locks and worker readiness contracts");
            if (PrivateValidationAgent.instrumentation != null) {
                var instrumentation = PrivateValidationAgent.instrumentation;
                var adapter = new Build4220Adapter();
                var support = adapter.initialize(instrumentation, loader);
                if (!support.supported()) {
                    var error = Build4220Adapter.class.getDeclaredField("transformationFailure"); error.setAccessible(true);
                    throw new AssertionError("Installed adapter did not admit: " + support + "; " + error.get(adapter));
                }
                var verified = new HashSet<String>();
                var audit = new java.lang.instrument.ClassFileTransformer() {
                    public byte[] transform(ClassLoader owner, String name, Class<?> type, java.security.ProtectionDomain domain, byte[] bytes) {
                        if (owner != loader) return null;
                        for (var ref : PrivateSaveGraph.SOURCES) if (ref.owner().equals(name)) {
                            if (!Arrays.equals(PrivateSaveGraph.methodFingerprint(loader, sources.get(name), ref), PrivateSaveGraph.methodFingerprint(loader, bytes, ref)))
                                throw new AssertionError("Original save changed: " + ref);
                            verified.add(name);
                        }
                        return null;
                    }
                };
                instrumentation.addTransformer(audit, true);
                try {
                    Class<?>[] originals = PrivateSaveGraph.SOURCES.stream().map(ref -> {
                        try { return Class.forName(ref.owner().replace('/', '.'), false, loader); }
                        catch (Exception failure) { throw new RuntimeException(failure); }
                    }).toArray(Class<?>[]::new);
                    instrumentation.retransformClasses(originals);
                    if (verified.size() != PrivateSaveGraph.SOURCES.size()) throw new AssertionError("Original-save audit incomplete");
                } finally { instrumentation.removeTransformer(audit); }
                System.out.println("VERIFIED (separate JVM, not saved): production adapter admission and unchanged original save bodies");
                adapter.close();
                Path moduleJar = Path.of(Build4220Adapter.class.getProtectionDomain().getCodeSource().getLocation().toURI());
                var registrations = pztools.extensions.api.GameHooks.class.getDeclaredField("observers"); registrations.setAccessible(true);
                int baseline = ((Map<?,?>)registrations.get(null)).size();
                for (int generation = 0; generation < 3; generation++) {
                    var moduleLoader = pztools.extensions.api.internal.ClassArchive.open(moduleJar,
                        "pztools.extensions.seamless", pztools.extensions.api.SaveProvider.class.getClassLoader());
                    var provider = (pztools.extensions.api.SaveProvider)moduleLoader.loadClass("pztools.extensions.seamless.SeamlessSaveProvider").getConstructor().newInstance();
                    if (!provider.initialize(instrumentation, loader).supported()) throw new AssertionError("Reloaded real adapter rejected");
                    provider.close();
                    if (((Map<?,?>)registrations.get(null)).size() != baseline) throw new AssertionError("Retired adapter retained observations");
                }
                long helpers = Arrays.stream(instrumentation.getAllLoadedClasses()).filter(c -> c.getClassLoader() == loader
                    && c.getName().equals("zombie.PzToolsSaveAccess$V1")).count();
                if (helpers != 1) throw new AssertionError("Reload leaked named game helpers: " + helpers);
                System.out.println("VERIFIED: installed adapter reload/retirement in three fresh module loaders; no observer or named-helper growth");
            }
        }
    }
}
