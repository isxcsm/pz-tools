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

    /** The corner lights the square's floor blood is tinted with, for the player. */
    public int[] bloodLight(IsoGridSquare square, int player) {
        bloodSquare = square;
        bloodPlayer = player;
        renderOneLevel_Blood(null, 0, 0, 0, 0, 0);
        return blood.clone();
    }
}
