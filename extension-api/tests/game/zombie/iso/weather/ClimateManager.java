package zombie.iso.weather;

/** Synthetic: the climate, as the game's: how far into the night it is (0 by day, 1 at night; night unless a test says). */
public final class ClimateManager {
    private static final ClimateManager instance = new ClimateManager();
    public static float night = 1f;

    public static ClimateManager getInstance() { return instance; }

    public float getNightStrength() { return night; }
}
