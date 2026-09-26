package pztools.extensions.api;

import java.lang.instrument.Instrumentation;

/** One module host per JVM. No provider may fall back after begin() has been called. */
public interface SaveModules {
    record Resolution(SaveProvider provider, String reason) { }
    Resolution resolve(String id, Instrumentation instrumentation, ClassLoader gameClasses);
    SaveTask begin(SaveProvider provider, SaveProvider.Context context) throws Exception;
}
