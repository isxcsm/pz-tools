package zombie.iso.fboRenderChunk;

import zombie.core.textures.ColorInfo;
import zombie.iso.IsoGridSquare;

/** Synthetic: the chunk renderer draws a square's objects with the square's light. */
public final class FBORenderCell {
    private ColorInfo sanitizeLightInfo(int player, IsoGridSquare square) { return square.lighting[player].lightInfo(); }

    /** The light the square's objects are drawn with, for the player. */
    public ColorInfo objectLight(int player, IsoGridSquare square) { return sanitizeLightInfo(player, square); }
}
