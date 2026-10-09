package zombie.iso;

import zombie.core.textures.ColorInfo;
import zombie.iso.objects.IsoGenerator;
import zombie.util.list.PZArrayList;

/** Synthetic: like the game's, a square has generator power when a generator's range in its chunk covers it. */
public final class IsoGridSquare {
    public int x, y, z;
    public IsoChunk chunk;
    public IsoCell cell;
    /** Walls on the west and north edge, a block that fills the square, and an opening in the floor to the floor below. */
    public boolean westWall, northWall, solid, openFloor;
    /** The questions the vision asked of any square. */
    public static int visionTests;
    public final PZArrayList<IsoObject> objects = new PZArrayList<>();
    /** The light of the square for each local player: full unless a test sets it. */
    public interface ILighting { ColorInfo lightInfo(); }
    private static final ILighting BRIGHT = () -> new ColorInfo(1f, 1f, 1f);
    public final ILighting[] lighting = { BRIGHT, BRIGHT, BRIGHT, BRIGHT };
    /** Sets the light of the square for the player (0: dark, 1: full). */
    public void setLight(int player, float light) { lighting[player] = () -> new ColorInfo(light, light, light); }
    /** Whether the square is in a room (a test sets it). */
    public boolean inRoom;
    public boolean isInARoom() { return inRoom; }
    public IsoGridSquare(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }
    public PZArrayList<IsoObject> getObjects() { return objects; }
    public IsoGenerator getGenerator() {
        for (int index = 0; index < objects.size(); index++) if (objects.get(index) instanceof IsoGenerator generator) return generator;
        return null;
    }

    /**
     * Whether the way to the square at the offset is clear, as the game asks it (the receiver is the square the line has
     * reached): blocked by a wall on the edge crossed, by a block, and between floors unless the upper one is open.
     */
    public LosUtil.TestResults testVisionAdjacent(int dx, int dy, int dz, boolean collide, boolean ignoreDoors) {
        visionTests++;
        IsoGridSquare other = cell == null ? null : cell.getGridSquare(x + dx, y + dy, z + dz);
        if (other == null) return LosUtil.TestResults.Clear;
        if (solid || other.solid) return LosUtil.TestResults.Blocked;
        if (dz != 0) return (dz > 0 ? other : this).openFloor ? LosUtil.TestResults.Clear : LosUtil.TestResults.Blocked;
        boolean acrossX = dx < 0 ? westWall : dx > 0 && other.westWall;
        boolean acrossY = dy < 0 ? northWall : dy > 0 && other.northWall;
        return acrossX || acrossY ? LosUtil.TestResults.Blocked : LosUtil.TestResults.Clear;
    }

    public boolean haveElectricity() { return chunk != null && chunk.isGeneratorPoweringSquare(x, y, z); }
}
