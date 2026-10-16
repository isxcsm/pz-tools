package zombie.iso;

import java.util.ArrayList;
import zombie.iso.objects.IsoGenerator;

/** Synthetic: 8 by 8 squares, which know the generators whose range reaches them. */
public final class IsoChunk {
    public static final int SIZE = 8;
    public final int wx, wy;
    public final ArrayList<int[]> generators = new ArrayList<>();
    public IsoCell cell;
    /** Whether the chunk is in a chunk map, as the game says (a chunk the cell lists but that is not in one yet is not loaded). */
    public boolean loaded = true;
    /** The objects the game lists as ones a generator can power. */
    public final java.util.Set<IsoObject> poweredObjects = java.util.Collections.newSetFromMap(new java.util.IdentityHashMap<>());
    public int getMinLevel() { return 0; }
    public int getMaxLevel() { return 2; }
    public IsoGridSquare[] getSquaresForLevel(int level) {
        var found = new IsoGridSquare[SIZE * SIZE];
        for (int y = 0; y < SIZE; y++) for (int x = 0; x < SIZE; x++) found[y * SIZE + x] = cell.getGridSquare(wx * SIZE + x, wy * SIZE + y, level);
        return found;
    }
    public void addObjectPoweredByGenerator(IsoObject object) { poweredObjects.add(object); }
    private final IsoGridSquare[][] levels = new IsoGridSquare[64][];
    /** Like the game's: the square at x, y within the chunk (0 to 7) and level z. */
    public IsoGridSquare getGridSquare(int x, int y, int z) {
        if (x < 0 || x >= SIZE || y < 0 || y >= SIZE || z < -32 || z > 31 || cell == null) return null;
        IsoGridSquare[] level = levels[z + 32];
        if (level != null && level[y * SIZE + x] != null) return level[y * SIZE + x];
        IsoGridSquare found = cell.getGridSquare(wx * SIZE + x, wy * SIZE + y, z);
        // The cell keeps its squares for good here, so a square found once is kept (and found again without a key built).
        if (found != null) {
            if (level == null) levels[z + 32] = level = new IsoGridSquare[SIZE * SIZE];
            level[y * SIZE + x] = found;
        }
        return found;
    }
    public IsoChunk(int wx, int wy) { this.wx = wx; this.wy = wy; }
    public void addGeneratorPos(int x, int y, int z) {
        for (int[] at : generators) if (at[0] == x && at[1] == y && at[2] == z) return;
        generators.add(new int[] { x, y, z });
    }
    public void removeGeneratorPos(int x, int y, int z) { generators.removeIf(at -> at[0] == x && at[1] == y && at[2] == z); }
    public boolean isGeneratorPoweringSquare(int x, int y, int z) {
        for (int[] at : generators) if (IsoGenerator.isPoweringSquare(at[0], at[1], at[2], x, y, z)) return true;
        return false;
    }
}
