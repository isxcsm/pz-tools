package fmod.fmod;

import java.util.HashMap;
import java.util.Map;

/**
 * Synthetic: the emitter the UI sounds play from. The game scales a sound by its setVolume (a channel's volume set direct is
 * set again from it with each tick); here it is kept by sound, the last for each.
 */
public final class FMODSoundEmitter {
    public final Map<Long, Float> volumes = new HashMap<>();
    /** How many times setVolume was called, for the tests that watch what a frame costs. */
    public int volumeCalls;

    public void setVolume(long id, float volume) {
        volumeCalls++;
        volumes.put(id, volume);
    }

    /** How many times it was ticked out of the game's own update (a level given to a sound as it starts is applied then). */
    public int ticks;

    public void tick() {
        ticks++;
    }
}
