package pztools.extensions.api;

import java.lang.instrument.Instrumentation;
import java.util.Map;

/** Control-plane contract; tick never performs archive I/O or waits for retirement. */
public interface ContinuousModules {
    record Apply(String processId, String worldId, long expectedRevision, long revision,
                 String moduleId, boolean forceVersion, Map<String, String> config) {
        public Apply { config = Map.copyOf(config); }
    }
    record Status(String state, String reason, String processId, String worldId, String generation,
                  long appliedRevision, String moduleVersion, String moduleSha256, String diagnostics) { }
    Status apply(Apply request, Instrumentation instrumentation, ClassLoader gameClasses, String gameVersion);
    void tick(ContinuousProvider.Context context);
    void revoke(String reason);
    Status deactivate(String reason);
    Status status();
}
