package zombie.iso;

import zombie.core.textures.ColorInfo;
import zombie.iso.objects.IsoGenerator;
import zombie.iso.objects.IsoWorldInventoryObject;
import zombie.util.list.PZArrayList;

/** Synthetic: like the game's, a square has generator power when a generator's range in its chunk covers it. */
public final class IsoGridSquare {
    public int x, y, z;
    public IsoChunk chunk;
    public IsoCell cell;
    /** Walls on the west and north edge, a block that fills the square, and an opening in the floor to the floor below. */
    public boolean westWall, northWall, solid, openFloor;
    /** A door frame and a window frame on the north and west edge (walls the vision does not ask about), and whether the doors are open. */
    public boolean northDoor, westDoor, northWindow, westWindow, doorOpen;
    /** Like the game's, for each player the edges the game cuts away to show the player: 1 the north one, 2 the west one. */
    public final int[] cutaway = new int[4];
    /** The questions the vision asked of any square. */
    public static int visionTests;
    public final PZArrayList<IsoObject> objects = new PZArrayList<>();

    /** Like the game's: a fire leaves each object of the square burnt, each of its containers emptied and taken away. */
    public void BurnWalls(boolean explode, boolean burnFloor) {
        for (int index = 0; index < objects.size(); index++) {
            IsoObject object = objects.get(index);
            for (int at = 0; at < object.getContainerCount(); at++) {
                object.getContainerByIndex(at).removeItemsFromProcessItems();
                object.getContainerByIndex(at).removeAllItems();
            }
            object.containers.clear();
        }
    }

    /** The floor items the next load reads, each old enough for the sandbox's world item removal to take. */
    public final java.util.ArrayList<IsoWorldInventoryObject> saved = new java.util.ArrayList<>();
    /** Like the game's: a floor item the removal would take is left out unless its own flag keeps it. */
    public void load(java.nio.ByteBuffer input, int version, boolean debug) {
        for (IsoWorldInventoryObject item : saved) if (item.isIgnoreRemoveSandbox()) { item.square = this; objects.add(item); }
        saved.clear();
    }
    /** The square's 8 corner lights (0xAABBGGRR) as the game keeps them: the same for every player here. */
    public final int[] vertLight = new int[8];

    public int getVertLight(int corner, int player) { return vertLight[corner]; }
    /** Like the game's: the light at x, y across the square (0 to 1), from its corners for the player the frame is drawn for. */
    public void interpolateLight(ColorInfo info, float x, float y) {
        x = Math.max(0f, Math.min(1f, x));
        y = Math.max(0f, Math.min(1f, y));
        int player = IsoCamera.frameState.playerIndex;
        int tl = getVertLight(0, player), tr = getVertLight(1, player), br = getVertLight(2, player), bl = getVertLight(3, player);
        info.r = across(tl, tr, br, bl, 0, x, y);
        info.g = across(tl, tr, br, bl, 8, x, y);
        info.b = across(tl, tr, br, bl, 16, x, y);
        info.a = across(tl, tr, br, bl, 24, x, y);
    }
    private static float across(int tl, int tr, int br, int bl, int shift, float x, float y) {
        float a = 0.003921569f * (tl >>> shift & 0xFF), b = 0.003921569f * (tr >>> shift & 0xFF);
        float c = 0.003921569f * (br >>> shift & 0xFF), d = 0.003921569f * (bl >>> shift & 0xFF);
        float top = a + (b - a) * x, bottom = d + (c - d) * x;
        return top + (bottom - top) * y;
    }
    /** The light of the square for each local player: full unless a test sets it; with the light sources that reach it. */
    public interface ILighting {
        ColorInfo lightInfo();
        default int resultLightCount() { return 0; }
        default ResultLight getResultLight(int index) { return null; }
        /** Whether the square is in the player's sight (in the vision cone, not behind a wall): yes unless a test says. */
        default boolean bCouldSee() { return true; }
        /** Like the game's: whether the player sees the square now; a square in sight in the dark is (its light 0 in game). */
        default boolean bCanSee() { return bCouldSee(); }
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
    /** Whether the square is in a room (a test sets it), and the room (none in a player-built room the game made no room of). */
    public boolean inRoom;
    public zombie.iso.areas.IsoRoom room;
    public boolean isInARoom() { return inRoom; }
    public zombie.iso.areas.IsoRoom getRoom() { return room; }
    public IsoGridSquare(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }
    /** The square's floor object, as a test sets it (none: the square has no floor). */
    public IsoObject floor;
    public IsoObject getFloor() { return floor; }
    /** Like the game's: the square's light for the player. */
    public ColorInfo getLightInfo(int player) { return lighting[player].lightInfo(); }
    /** How many times the square's chunk level was to be drawn again, and the flags of the last. */
    public int redraws;
    public long redrawFlags;
    public void invalidateRenderChunkLevel(long flags) { redraws++; redrawFlags = flags; }
    /** Like the game's, the square's flags: here its walls (WallN, WallW; both as WallNW), door frames and window frames. */
    public boolean hasProperty(zombie.iso.SpriteDetails.IsoFlagType flag) {
        return switch (flag) {
            case WallN -> northWall && !westWall;
            case WallW -> westWall && !northWall;
            case WallNW -> northWall && westWall;
            case DoorWallN -> northDoor;
            case DoorWallW -> westDoor;
            case WindowN -> northWindow;
            case WindowW -> westWindow;
            default -> false;
        };
    }
    /** A corner post on the square's south-east corner (WallSE). */
    public boolean cornerSE;
    /** Like the game's, from the square's properties: a wall or a window's cuts its side (cutN, cutW); a corner post. */
    public boolean has(zombie.iso.SpriteDetails.IsoFlagType flag) {
        return switch (flag) {
            case cutN -> northWall || northWindow;
            case cutW -> westWall || westWindow;
            case WallSE -> cornerSE;
            default -> hasProperty(flag);
        };
    }
    /** Like the game's: whether an object of the type stands on the square; here the door frames. */
    public boolean has(zombie.iso.SpriteDetails.IsoObjectType type) {
        return switch (type) {
            case doorFrN -> northDoor;
            case doorFrW -> westDoor;
        };
    }
    public boolean hasClosedDoorOnEdge(IsoDirections edge) { return !doorOpen && (edge == IsoDirections.N ? northDoor : edge == IsoDirections.W && westDoor); }
    public int getPlayerCutawayFlag(int player, long currentTimeMillis) { return cutaway[player]; }
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

    /** Whether the grid never powers the square (a NoPower zone, a player-built room): a test sets it. */
    public boolean noPower;
    public boolean isNoPower() { return noPower; }

    public boolean haveElectricity() { return chunk != null && chunk.isGeneratorPoweringSquare(x, y, z); }

    /** Synthetic: the game takes the square's properties again from its objects; the API's hook goes at its end. */
    public int recalcs;

    public void RecalcProperties() { recalcs++; }

    // The objects area: what a square filter asks (free, outside, water), and the removal of an object with its recalculations.
    public boolean freeSquare = true, outsideSquare, waterFloor;
    public int neighbourRecalcs;
    public boolean isFree(boolean mustNotHaveMovingObjects) { return freeSquare; }
    public boolean isOutside() { return outsideSquare; }
    public boolean isWaterSquare() { return waterFloor; }
    /** Like the game's: the object leaves the square's list; its place in the list, or -1. */
    public int transmitRemoveItemFromSquare(IsoObject object) {
        int at = objects.indexOf(object);
        if (at >= 0) objects.remove(at);
        return at;
    }
    public void RecalcAllWithNeighbours(boolean dirty) { neighbourRecalcs++; }

    /** Synthetic: the shader of the walls cut away for the player, as the game's: its uniforms set each time it starts drawing. */
    public static final class CutawayNoDepthShader extends zombie.core.opengl.Shader {
        @Override public int getID() { return 10; }

        public void startRenderThread(zombie.core.textures.TextureDraw draw) {
            org.lwjgl.opengl.GL20.glUniform1i(org.lwjgl.opengl.GL20.glGetUniformLocation(getID(), "DIFFUSE"), 0);
        }
    }
}
