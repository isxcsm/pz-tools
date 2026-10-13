package zombie.iso.areas.isoregion;

import java.util.HashMap;
import java.util.Map;
import zombie.iso.areas.isoregion.regions.IsoWorldRegion;

/**
 * Synthetic: the game's region data, as the extension API reads it. The game's thread reads the data root its worker
 * thread last handed over, and swaps in a new one as the worker has worked out what changed (IsoRegions.update).
 */
public final class IsoRegions {
    private static Object dataRoot = new Object();
    private static final Map<String, IsoWorldRegion> squares = new HashMap<>();

    private IsoRegions() { }

    public static IsoWorldRegion getIsoWorldRegion(int x, int y, int z) { return squares.get(x + "," + y + "," + z); }

    /** Test: a rectangle of squares of one level in a region (null: in none). Seen as it is once the data is swapped. */
    public static void set(IsoWorldRegion region, int x, int y, int w, int h, int z) {
        for (int row = y; row < y + h; row++)
            for (int column = x; column < x + w; column++) {
                if (region == null) squares.remove(column + "," + row + "," + z);
                else squares.put(column + "," + row + "," + z, region);
            }
    }

    /** Test: the worker's data swapped in, as the game does once a frame at most. */
    public static void swap() { dataRoot = new Object(); }
}
