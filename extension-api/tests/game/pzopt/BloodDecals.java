package pzopt;

import zombie.iso.IsoChunk;

/** Synthetic: PZ Optimization's floor blood, its squares' lights filled by the chunk renderer's rules as it draws a level. */
public final class BloodDecals {
    /** Fills the lights of a chunk level's 64 squares: r, g, b and 1 for a square drawn. */
    public interface SquareRules {
        void fill(IsoChunk chunk, int level, int player, long squares, float[] lights);
    }

    static final class Cache {
        final float[] sq = new float[256];
    }

    private static float[] squares(Cache cache, IsoChunk chunk, int level, int player, SquareRules rules) {
        java.util.Arrays.fill(cache.sq, 0f);
        rules.fill(chunk, level, player, -1L, cache.sq);
        return cache.sq;
    }

    /** The lights the blood of a level is drawn with, as the rules fill them. */
    public static float[] lights(SquareRules rules) {
        return squares(new Cache(), null, 0, 0, rules);
    }
}
