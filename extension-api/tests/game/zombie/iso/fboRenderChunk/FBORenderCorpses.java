package zombie.iso.fboRenderChunk;

import zombie.core.textures.ColorInfo;
import zombie.iso.IsoGridSquare;

/** Synthetic: the chunk renderer's corpses, drawn as models lit by the square they lie on. */
public final class FBORenderCorpses {
    static final class BodyParams {
        final ColorInfo ambient = new ColorInfo();
        float x, y;

        void initAmbient(IsoGridSquare square) {
            ambient.set(1f, 1f, 1f, 1f);
            if (square != null) square.interpolateLight(ambient, x % 1f, y % 1f);
        }
    }

    /** The light a corpse at x, y on the square is drawn with, as the game's body params take it for the model. */
    public static ColorInfo corpseLight(IsoGridSquare square, float x, float y) {
        var params = new BodyParams();
        params.x = x;
        params.y = y;
        params.initAmbient(square);
        return params.ambient;
    }
}
