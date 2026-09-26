package pztools.extensions.runtime;

import pztools.extensions.api.*;
import pztools.extensions.api.internal.ClassArchive;
import java.lang.instrument.Instrumentation;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** One bounded deployment catalogue and loader per module. UI and JVM consume the same version rules. */
public final class ModuleHost implements SaveModules {
    private record Definition(String id, String jar, String namespace, String entry, VersionSupport support) { }
    private final Path directory;
    private final Map<String, Definition> definitions = new HashMap<>();
    private final Map<String, Resolution> resolutions = new HashMap<>();
    private final CheckpointRuntime runtime = new CheckpointRuntime(64L * 1024 * 1024);
    private ClassLoader boundGameLoader;
    public ModuleHost(Path directory) throws Exception {
        this.directory = directory.toAbsolutePath().normalize();
        byte[] bytes;
        try (var input = Files.newInputStream(this.directory.resolve("catalog.tsv"))) { bytes = input.readNBytes(65537); }
        if (bytes.length > 65536) throw new IllegalArgumentException("Oversized extension catalogue");
        for (String line : new String(bytes, StandardCharsets.UTF_8).split("\\R")) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] p = line.split("\t", -1);
            if (p.length != 10 || definitions.size() >= 64 || !p[0].matches("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+")
                    || !p[2].matches("pztools\\.extensions\\.[A-Za-z0-9_.]+") || !p[3].startsWith(p[2] + ".")
                    || !p[3].matches("[A-Za-z0-9_.]+") || !p[4].matches("[a-z0-9-]+\\.jar"))
                throw new IllegalArgumentException("Invalid extension catalogue row");
            var range = new VersionSupport(p[5], p[6].equals("-") ? null : p[6], p[7].equals("-") ? null : p[7]);
            if (definitions.putIfAbsent(p[0], new Definition(p[0], p[4], p[2], p[3], range)) != null)
                throw new IllegalArgumentException("Duplicate module identity");
        }
    }
    @Override public synchronized Resolution resolve(String id, Instrumentation instrumentation, ClassLoader gameClasses,
                                                      String gameVersion, boolean forceVersion) {
        Definition definition = definitions.get(id);
        if (definition == null) return new Resolution(null, "unknown-provider");
        if (!forceVersion && !definition.support.matches(gameVersion))
            return new Resolution(null, gameVersion == null ? "version-unknown" : "version-mismatch");
        if (boundGameLoader != null && boundGameLoader != gameClasses) return new Resolution(null, "game-loader-changed");
        if (resolutions.containsKey(id)) return resolutions.get(id);
        boundGameLoader = gameClasses;
        Resolution result;
        try {
            var loader = ClassArchive.open(directory.resolve(definition.jar), definition.namespace, ModuleHost.class.getClassLoader());
            var provider = (SaveProvider)loader.loadClass(definition.entry).getConstructor().newInstance();
            if (!provider.id().equals(id)) throw new IllegalStateException("Provider identity mismatch");
            // Force affects only declared versions, not the provider's essential bytecode/runtime checks.
            var support = provider.initialize(instrumentation, gameClasses);
            result = support.supported() ? new Resolution(new SaveProvider() {
                public String id() { return provider.id(); }
                public Support inspect(Context context) {
                    if (!context.forceVersion() && !definition.support.matches(context.gameVersion()))
                        return new Support(false, context.gameVersion() == null ? "version-unknown" : "version-mismatch");
                    return provider.inspect(context);
                }
                public boolean readyToCapture(Context context) throws Exception { return provider.readyToCapture(context); }
                public PreparedSave capture(Context context, long maximumBytes) throws Exception {
                    Support checked = inspect(context);
                    if (!checked.supported()) throw new IllegalStateException(checked.reason());
                    return provider.capture(context, maximumBytes);
                }
            }, null) : new Resolution(null, support.reason());
        } catch (Exception | LinkageError failure) { result = new Resolution(null, "module-unavailable"); }
        resolutions.put(id, result);
        return result;
    }
    @Override public SaveTask begin(SaveProvider provider, SaveProvider.Context context) throws Exception {
        return runtime.begin(provider, context);
    }
}