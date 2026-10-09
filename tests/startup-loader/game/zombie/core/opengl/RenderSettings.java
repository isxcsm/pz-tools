package zombie.core.opengl;

import zombie.characters.IsoPlayer;

/** Synthetic: the screen's light for a player, worked out as the game's is at night. */
public final class RenderSettings {
    public static final class PlayerRenderSettings {
        private float ambient;
        private float rmod = 1.0f, gmod = 1.0f, bmod = 1.0f;

        /**
         * Like the game's: the climate's ambient, Cat's Eyes keeping it at 0.2 or more, then the sandbox's night darkness
         * lifting it (ambient = lift + (1 - lift) x ambient).
         */
        private void updateRenderSettings(int playerIndex, IsoPlayer player) {
            float lift = player == null ? 0.0f : player.nightLift;
            ambient = player == null ? 0.0f : player.climateAmbient;
            if (ambient < 0.2f && player != null && player.catsEyes) ambient = 0.2f;
            ambient = lift + (1.0f - lift) * ambient;
            rmod = gmod = bmod = player == null ? 1.0f : player.nightTint;
        }

        public float tintFor(IsoPlayer player) {
            updateRenderSettings(0, player);
            return gmod;
        }

        public float ambientFor(IsoPlayer player) {
            updateRenderSettings(0, player);
            return ambient;
        }
    }
}
