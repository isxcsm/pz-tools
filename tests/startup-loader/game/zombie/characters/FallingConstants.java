package zombie.characters;

/** Synthetic: the speeds a fall is judged by, from heights as the game's are (speed squared is twice the acceleration times the height). */
public final class FallingConstants {
    public static final float IsoFallAcceleration = 5.0010414f;
    public static final float isFallingThreshold, hardFallThreshold, lethalFallThreshold;

    static {
        isFallingThreshold = getIsoImpactSpeedFromHeight(0.35f);
        hardFallThreshold = getIsoImpactSpeedFromHeight(1.5f);
        lethalFallThreshold = getIsoImpactSpeedFromHeight(3.5f);
    }

    public static float getIsoImpactSpeedFromHeight(float height) {
        float time = (float)Math.sqrt(height * 2f / IsoFallAcceleration);
        return IsoFallAcceleration * time;
    }

    public static boolean isFall(float speed) { return speed >= isFallingThreshold; }
}
