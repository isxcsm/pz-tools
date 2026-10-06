package zombie.iso;

import java.util.ArrayList;
import zombie.iso.objects.IsoGenerator;

/** Synthetic: 8 by 8 squares, which know the generators whose range reaches them. */
public final class IsoChunk {
    public static final int SIZE = 8;
    public final int wx, wy;
    public final ArrayList<int[]> generators = new ArrayList<>();
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
