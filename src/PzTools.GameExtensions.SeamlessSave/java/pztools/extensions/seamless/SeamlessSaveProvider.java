package pztools.extensions.seamless;

import pztools.extensions.api.SaveProvider;
import java.util.List;

/** Optional version-sensitive module. The B42.20 adapter retains original world saving and drains database writes. */
public final class SeamlessSaveProvider implements SaveProvider {
    /** Owned by this module, not by the bridge, UI, backup engine or common extension runtime. */
    public interface GameAdapter {
        default Support initialize(java.lang.instrument.Instrumentation instrumentation, ClassLoader gameClasses) throws Exception {
            return new Support(true, null);
        }
        Support inspect(Context context);
        PreparedSave capture(Context context, long maximumBytes) throws Exception;
    }
    private final List<GameAdapter> adapters;
    public SeamlessSaveProvider() { this(List.of(new pztools.extensions.seamless.b4220.Build4220Adapter())); }
    public SeamlessSaveProvider(List<GameAdapter> adapters) { this.adapters = List.copyOf(adapters); }
    @Override public Support initialize(java.lang.instrument.Instrumentation instrumentation, ClassLoader gameClasses) throws Exception {
        int matches = 0;
        String reason = "unsupported-game-build";
        for (var adapter : adapters) {
            var support = adapter.initialize(instrumentation, gameClasses);
            if (support.supported()) matches++; else reason = support.reason();
        }
        return new Support(matches == 1, matches > 1 ? "ambiguous-game-adapter" : matches == 1 ? null : reason);
    }
    @Override public String id() { return "pztools.seamless-save"; }
    @Override public Support inspect(Context context) {
        context.requireGameThread();
        long matches = adapters.stream().filter(adapter -> adapter.inspect(context).supported()).count();
        return matches == 1 ? new Support(true, null)
            : new Support(false, matches == 0 ? "adapter-validation-required" : "ambiguous-game-adapter");
    }
    @Override public PreparedSave capture(Context context, long maximumBytes) throws Exception {
        context.requireGameThread();
        var supported = adapters.stream().filter(adapter -> adapter.inspect(context).supported()).toList();
        if (supported.size() != 1) throw new UnsupportedOperationException(inspect(context).reason());
        return supported.getFirst().capture(context, maximumBytes);
    }
}
