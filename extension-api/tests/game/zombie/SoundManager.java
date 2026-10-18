package zombie;

import fmod.fmod.FMODSoundEmitter;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Synthetic: the sound manager the game runs (its {@code instance}, declared here as the game declares it); the UI sounds it
 * was asked to play, by name, those still playing (a test ends a one-shot by taking its id out) and those stopped, and the
 * volumes a test sets.
 */
public class SoundManager extends BaseSoundManager {
    public static BaseSoundManager instance = new SoundManager();

    public final List<String> played = new ArrayList<>();
    /** The ids of the sounds playing now, and of those stopped (in order, each stop once). */
    public final Set<Long> playing = new LinkedHashSet<>();
    public final List<Long> stopped = new ArrayList<>();
    public final FMODSoundEmitter emitter = new FMODSoundEmitter();
    public float soundVolume = 1f, ambientVolume = 1f, musicVolume = 1f, vehicleEngineVolume = 1f;

    @Override public long playUISound(String name) {
        played.add(name);
        long id = played.size();
        playing.add(id);
        return id;
    }

    @Override public boolean isPlayingUISound(long id) { return playing.contains(id); }

    @Override public void stopUISound(long id) {
        if (playing.remove(id)) stopped.add(id);
    }

    public FMODSoundEmitter getUIEmitter() { return emitter; }

    @Override public float getSoundVolume() { return soundVolume; }

    @Override public float getAmbientVolume() { return ambientVolume; }

    @Override public float getMusicVolume() { return musicVolume; }

    @Override public float getVehicleEngineVolume() { return vehicleEngineVolume; }
}
