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
    /** The light of the square for each local player: full unless a test sets it; with the light sources that reach it. */
    public interface ILighting {
        ColorInfo lightInfo();
        default int resultLightCount() { return 0; }
        default ResultLight getResultLight(int index) { return null; }
        /** Whether the square is in the player's sight (in the vision cone, not behind a wall): yes unless a test says. */
        default boolean bCouldSee() { return true; }
        /** Like the game's: whether the player sees the square now, in sight and with some light on it. */
        default boolean bCanSee() { return bCouldSee() && lightInfo().r > 0.05f; }
        /** Whether the player has ever seen the square: yes unless a test says. */
        default boolean bSeen() { return true; }
    }
    /** Makes the square one the player has never seen (an unexplored room), its light as it was. */
    public void setUnexplored(int player) {
        ILighting seen = lighting[player];
        lighting[player] = new ILighting() {
            public ColorInfo lightInfo() { return seen.lightInfo(); }
            public int resultLightCount() { return seen.resultLightCount(); }
            public ResultLight getResultLight(int index) { return seen.getResultLight(index); }
            public boolean bCouldSee() { return false; }
            public boolean bSeen() { return false; }
        };
    }
    /** Makes the square one out of the player's sight (out of the vision cone), its light as it was. */
    public void setUnseen(int player) {
        ILighting seen = lighting[player];
        lighting[player] = new ILighting() {
            public ColorInfo lightInfo() { return seen.lightInfo(); }
            public int resultLightCount() { return seen.resultLightCount(); }
            public ResultLight getResultLight(int index) { return seen.getResultLight(index); }
            public boolean bCouldSee() { return false; }
        };
    }
    /** A light source that reaches a square. */
    public static final class ResultLight {
        public static final int RLF_NONE = 0, RLF_ROOMLIGHT = 1, RLF_TORCH = 2;
        public int id, x, y, z, radius, flags;
        public float r, g, b;
        public ResultLight(int x, int y, int radius, float light, int flags) { this.x = x; this.y = y; this.radius = radius; r = g = b = light; this.flags = flags; }
    }
    /** Sets the light of the square for the player, and the light sources that reach it. */
    public void setLight(int player, float light, ResultLight... sources) {
        lighting[player] = new ILighting() {
            public ColorInfo lightInfo() { return new ColorInfo(light, light, light); }
            public int resultLightCount() { return sources.length; }
            public ResultLight getResultLight(int index) { return sources[index]; }
        };
    }
    private static final ILighting BRIGHT = () -> new ColorInfo(1f, 1f, 1f);
    public final ILighting[] lighting = { BRIGHT, BRIGHT, BRIGHT, BRIGHT };
    /** Sets the light of the square for the player (0: dark, 1: full). */
    public void setLight(int player, float light) { setLight(player, light, new ResultLight[0]); }
    /** Whether the square is in a room (a test sets it). */
    public boolean inRoom;
    public boolean isInARoom() { return inRoom; }
    public IsoGridSquare(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }
    /** Like the game's, the square's flags: here its walls (WallN, WallW; both as WallNW). */
    public boolean hasProperty(zombie.iso.SpriteDetails.IsoFlagType flag) {
        return switch (flag) {
            case WallN -> northWall && !westWall;
            case WallW -> westWall && !northWall;
            case WallNW -> northWall && westWall;
            default -> false;
        };
    }
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
