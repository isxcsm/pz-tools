package zombie.characters;

/** Synthetic: a character's sounds; the voices it was asked to play, counted. */
public class BaseCharacterSoundEmitter {
    public int vocals;
    private long next = 1;

    public long playVocals(String name) {
        vocals++;
        return next++;
    }

    public void stopSoundLocal(long event) { }
}
