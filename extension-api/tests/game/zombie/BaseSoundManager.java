package zombie;

/** Synthetic: the game's sound manager, as far as the API uses it (the titles' UI sounds, the volume of each master). */
public abstract class BaseSoundManager {
    public abstract long playUISound(String name);

    public abstract float getSoundVolume();

    public abstract float getAmbientVolume();

    public abstract float getMusicVolume();

    public abstract float getVehicleEngineVolume();
}
