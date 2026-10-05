package pztools.extensions.api;

import java.lang.instrument.Instrumentation;

/** One module host per JVM. No provider may fall back after begin() has been called. */
public interface SaveModules {
    record Resolution(SaveProvider provider, String reason) { }
    Resolution resolve(String id, Instrumentation instrumentation, ClassLoader gameClasses, String gameVersion, boolean forceVersion);
    /** The app moved: same runtime bytes, new folder. Modules whose bytes match keep running; WATCH is untouched. */
    void relocate(java.nio.file.Path directory) throws Exception;
    void close() throws Exception;
    SaveTask begin(SaveProvider provider, SaveProvider.Context context) throws Exception;
}
