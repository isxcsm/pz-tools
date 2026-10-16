package zombie.iso.fboRenderChunk;

import zombie.core.textures.ColorInfo;
import zombie.iso.IsoGridSquare;

/** Synthetic: the chunk renderer draws a square's objects with the square's light. */
public final class FBORenderCell {
    private ColorInfo sanitizeLightInfo(int player, IsoGridSquare square) { return square.lighting[player].lightInfo(); }

    /** The light the square's objects are drawn with, for the player. */
    public ColorInfo objectLight(int player, IsoGridSquare square) { return sanitizeLightInfo(player, square); }

    // Like the game's: a chunk level's squares are read when the lighting says it changed.
    private boolean updateChunkLevelLighting(int player, int wx, int wy, int level) {
        return zombie.iso.LightingJNI.getChunkDirty(player, wx, wy, level + 32);
    }

    /** Whether the renderer reads the chunk level's squares for the player. */
    public boolean lightingDirty(int player, int wx, int wy, int level) { return updateChunkLevelLighting(player, wx, wy, level); }

    // The floor's blood of the square, tinted with its four corners (read as the game reads them).
    private IsoGridSquare bloodSquare;
    private int bloodPlayer;
    private final int[] blood = new int[4];

    private void renderOneLevel_Blood(zombie.iso.IsoChunk chunk, int z, int minX, int minY, int maxX, int maxY) {
        blood[0] = bloodSquare.getVertLight(0, bloodPlayer);
        blood[1] = bloodSquare.getVertLight(1, bloodPlayer);
        blood[2] = bloodSquare.getVertLight(2, bloodPlayer);
        blood[3] = bloodSquare.getVertLight(3, bloodPlayer);
    }

    /** How many floors were drawn. */
    public int floors;

    /** Like the game's: a chunk level's floor square drawn (its floor objects; here only counted). */
    public void renderFloor(IsoGridSquare square) {
        if (square.getFloor() == null) return;
        floors++;
    }

    /** Like the game's: a chunk level drawn: its floors one after another, then its snow. */
    private void renderOneLevel(zombie.iso.IsoChunk chunk, int level, zombie.iso.IsoCell.PerPlayerRender render, int player, long flags,
            zombie.core.opengl.Shader floorShader, zombie.core.opengl.Shader wallShader) {
        for (int index = 0; index < zombie.iso.IsoCell.SolidFloor.size(); index++) renderFloor(zombie.iso.IsoCell.SolidFloor.get(index));
        FBORenderSnow.getInstance().RenderSnow(chunk, level);
    }

    /** Like PZ Optimization's: the level's snow, drawn by itself when the floors' draws are replayed on the game's thread. */
    void pzoptBakeSnow(zombie.iso.IsoChunk chunk, int level) { FBORenderSnow.getInstance().RenderSnow(chunk, level); }

    /** A chunk level's snow replayed, as PZ Optimization does when the floors were recorded elsewhere (the floors are not drawn here). */
    public void replay(IsoGridSquare square) { pzoptBakeSnow(square.chunk, square.z); }

    /** A chunk level of this one floor square drawn (allocating nothing). */
    public void level(IsoGridSquare square) {
        zombie.iso.IsoCell.SolidFloor.clear();
        zombie.iso.IsoCell.SolidFloor.add(square);
        renderOneLevel(square.chunk, square.z, null, 0, 0L, null, null);
    }

    /** A chunk level of these floor squares drawn, in this order. */
    public void level(IsoGridSquare first, IsoGridSquare... more) {
        zombie.iso.IsoCell.SolidFloor.clear();
        zombie.iso.IsoCell.SolidFloor.add(first);
        for (IsoGridSquare square : more) zombie.iso.IsoCell.SolidFloor.add(square);
        renderOneLevel(first.chunk, first.z, null, 0, 0L, null, null);
    }

    /** The corner lights the square's floor blood is tinted with, for the player. */
    public int[] bloodLight(IsoGridSquare square, int player) {
        bloodSquare = square;
        bloodPlayer = player;
        renderOneLevel_Blood(null, 0, 0, 0, 0, 0);
        return blood.clone();
    }
}
