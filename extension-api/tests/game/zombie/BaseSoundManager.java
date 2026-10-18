package zombie;

/** Synthetic: the game's sound manager, as far as the API plays through it (the UI sounds of the titles). */
public abstract class BaseSoundManager {
    public static BaseSoundManager instance = new SoundManager();

    public abstract long playUISound(String name);
}
