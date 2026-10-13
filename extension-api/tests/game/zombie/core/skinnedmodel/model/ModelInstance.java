package zombie.core.skinnedmodel.model;

import zombie.characters.IsoGameCharacter;
import zombie.core.textures.ColorInfo;
import zombie.iso.IsoGridSquare;

/**
 * Synthetic: a character's light, read from the square it stands on as the game reads it, and as PZ Optimization's copy of
 * the class reads it (a static form of its own, the same corners worked out the same way).
 */
public final class ModelInstance {
    public static final class PlayerData {
        public final ColorInfo ambient = new ColorInfo(), optimized = new ColorInfo();
        public IsoGridSquare square;
        public void update(IsoGameCharacter character) { updateLights(character, true); }
        private void updateLights(IsoGameCharacter character, boolean all) {
            if (square == null) return;
            square.interpolateLight(ambient, 0.25f, 0.75f);
            pzoptInterpolateLight(square, optimized, 0.25f, 0.75f);
        }
    }

    private static void pzoptInterpolateLight(IsoGridSquare square, ColorInfo info, float x, float y) { square.interpolateLight(info, x, y); }
}
