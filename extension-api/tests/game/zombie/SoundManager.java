package zombie;

import java.util.ArrayList;
import java.util.List;

/** Synthetic: the sound manager the game runs; the UI sounds it was asked to play, by name. */
public class SoundManager extends BaseSoundManager {
    public final List<String> played = new ArrayList<>();

    @Override public long playUISound(String name) {
        played.add(name);
        return played.size();
    }
}
