package pztools.extensions.runtime;

import pztools.extensions.api.*;
import pztools.extensions.api.internal.ClassArchive;
import java.lang.instrument.Instrumentation;
import java.nio.file.Path;
import java.util.HashMap;

/** Curated module discovery. One closed class-loader snapshot per module for the JVM lifetime. */
public final class ModuleHost implements SaveModules {
    private final Path directory;
    private final HashMap<String, Resolution> resolutions = new HashMap<>();
    private final CheckpointRuntime runtime = new CheckpointRuntime(64L * 1024 * 1024);
    private ClassLoader boundGameLoader;
    public ModuleHost(Path directory) { this.directory = directory.toAbsolutePath().normalize(); }

    @Override public synchronized Resolution resolve(String id, Instrumentation instrumentation, ClassLoader gameClasses) {
        if (!id.equals("pztools.seamless-save")) return new Resolution(null, "unknown-provider");
        if (boundGameLoader != null && boundGameLoader != gameClasses)
            return new Resolution(null, "game-loader-changed");
        if (resolutions.containsKey(id)) return resolutions.get(id);
        boundGameLoader = gameClasses;
        Resolution result;
        try {
            var loader = ClassArchive.open(directory.resolve("pztools-seamless-save.jar"),
                "pztools.extensions.seamless", ModuleHost.class.getClassLoader());
            var provider = (SaveProvider)loader.loadClass("pztools.extensions.seamless.SeamlessSaveProvider")
                .getConstructor().newInstance();
            if (!provider.id().equals(id)) throw new IllegalStateException("Provider identity mismatch");
            var support = provider.initialize(instrumentation, gameClasses);
            result = support.supported() ? new Resolution(provider, null) : new Resolution(null, support.reason());
        } catch (Exception | LinkageError failure) {
            result = new Resolution(null, "module-unavailable");
        }
        // Do not reload code after an ambiguous initialization or during a save.
        resolutions.put(id, result);
        return result;
    }

    @Override public SaveTask begin(SaveProvider provider, SaveProvider.Context context) throws Exception {
        return runtime.begin(provider, context);
    }
}
