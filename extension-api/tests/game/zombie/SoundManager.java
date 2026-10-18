package zombie;

import java.util.ArrayList;
import java.util.List;

/**
 * Synthetic: the sound manager the game runs (its {@code instance}, declared here as the game declares it); the UI sounds it
 * was asked to play, by name, and the volumes a test sets.
 */
public class SoundManager extends BaseSoundManager {
    public static BaseSoundManager instance = new SoundManager();

    public final List<String> played = new ArrayList<>();
    public float soundVolume = 1f, ambientVolume = 1f, musicVolume = 1f, vehicleEngineVolume = 1f;

    @Override public long playUISound(String name) {
        played.add(name);
        return played.size();
    }

    @Override public float getSoundVolume() { return soundVolume; }

    @Override public float getAmbientVolume() { return ambientVolume; }

    @Override public float getMusicVolume() { return musicVolume; }

    @Override public float getVehicleEngineVolume() { return vehicleEngineVolume; }
}
