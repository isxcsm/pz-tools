package pztools.extensions.seamless;

import pztools.extensions.api.SaveProvider;
import java.util.List;

/** Optional version-sensitive module. No built-in game adapter is claimed safe by this foundation release. */
public final class SeamlessSaveProvider implements SaveProvider {
    /** Owned by this module, not by the bridge, UI, backup engine or common extension runtime. */
    public interface GameAdapter {
        Support inspect(Context context);
        FrozenSnapshot capture(Context context, long maximumBytes) throws Exception;
    }
    private final List<GameAdapter> adapters;
    public SeamlessSaveProvider() { this(List.of()); }
    public SeamlessSaveProvider(List<GameAdapter> adapters) { this.adapters = List.copyOf(adapters); }
    @Override public String id() { return "pztools.seamless-save"; }
    @Override public Support inspect(Context context) {
        context.requireGameThread();
        long matches = adapters.stream().filter(adapter -> adapter.inspect(context).supported()).count();
        return matches == 1 ? new Support(true, null)
            : new Support(false, matches == 0 ? "adapter-validation-required" : "ambiguous-game-adapter");
    }
    @Override public FrozenSnapshot capture(Context context, long maximumBytes) throws Exception {
        context.requireGameThread();
        var supported = adapters.stream().filter(adapter -> adapter.inspect(context).supported()).toList();
        if (supported.size() != 1) throw new UnsupportedOperationException(inspect(context).reason());
        return supported.getFirst().capture(context, maximumBytes);
    }
}
