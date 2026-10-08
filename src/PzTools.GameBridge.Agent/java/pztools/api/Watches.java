package pztools.api;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.function.IntSupplier;
import pztools.bridge.ApiHooks;

/**
 * What the game's frame job learns from the bootstrap's hooks instead of looking each frame: that the world's cell was stored
 * (a world started or was left), and that the helicopter's state or flag was stored. The hooks only count (on any thread); each
 * user of a count remembers the last it saw, so the frame does nothing but compare two ints until one moves.
 *
 * <p>When a hook is not in the game's class (the bootstrap is older, the class has changed, or has not loaded), the count means
 * nothing and a user is told to look at every frame, as before the hooks: events are never lost, the frame only costs more.
 * {@link #status} says which it is, for {@code PZToolsAPI.hooks()}.
 */
final class Watches {
    static final String HELICOPTER = "Helicopter.events", WORLD = "IsoWorld.change";

    /** The world's cell, and the helicopter's state and flag, as counted by the hooks. */
    static final Kind WORLD_CELL = new Kind(Watches::worldWatched, Watches::worldWrites, "IsoWorld.writes:currentCell", "looks at the world's cell");
    static final Kind HELICOPTER_FLIGHT = new Kind(Watches::helicopterWatched, Watches::helicopterWrites, "Helicopter.writes:flight",
        "reads the helicopter's state");

    // False once the bootstrap proves to be one from before the counts (a call into it fails to link).
    private static volatile boolean linked = true;

    private Watches() { }

    /** One count the hooks keep, with how to tell that it is kept. */
    record Kind(BooleanSupplier watched, IntSupplier writes, String hook, String fallback) {
        /** A user of the count: the frame job of one area. */
        Seen user() { return new Seen(this); }
    }

    /** What one user last saw of a count. */
    static final class Seen {
        private final Kind kind;
        private int seen;
        private boolean looked;

        private Seen(Kind kind) { this.kind = kind; }

        /**
         * Whether the user has to look now: the first time, after the count moved, and at every call while the hook is missing.
         * Both are the game thread's; the count is written by any thread, after the store it counts.
         */
        boolean moved() {
            if (!kind.watched.getAsBoolean()) { looked = false; return true; }
            int now = kind.writes.getAsInt();
            if (looked && now == seen) return false;
            looked = true;
            seen = now;
            return true;
        }
    }

    private static boolean helicopterWatched() { try { return linked && ApiHooks.helicopterWatched(); } catch (LinkageError older) { linked = false; return false; } }

    private static int helicopterWrites() { try { return ApiHooks.helicopterWrites(); } catch (LinkageError older) { linked = false; return 0; } }

    private static boolean worldWatched() { try { return linked && ApiHooks.worldWatched(); } catch (LinkageError older) { linked = false; return false; } }

    private static int worldWrites() { try { return ApiHooks.worldWrites(); } catch (LinkageError older) { linked = false; return 0; } }

    /** For {@code PZToolsAPI.hooks()}: whether each area is told by the hooks or looks at every frame, and why. */
    static Map<String, String> status() {
        var all = new LinkedHashMap<String, String>();
        all.put(HELICOPTER, describe(HELICOPTER_FLIGHT));
        all.put(WORLD, describe(WORLD_CELL));
        return all;
    }

    private static String describe(Kind kind) {
        if (kind.watched.getAsBoolean()) return ApiHooks.APPLIED;
        String why;
        try { why = ApiHooks.hookStatus().getOrDefault(kind.hook, "unknown"); }
        catch (LinkageError older) { why = "this bootstrap does not count them"; }
        return "polled: " + why + "; every frame " + kind.fallback;
    }
}
