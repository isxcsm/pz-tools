package zombie.iso;

import zombie.characters.IsoGameCharacter;

/** Synthetic: the corpses around a character, as the game counts them for the sickness they make. */
public final class CorpseCount {
    public static final CorpseCount instance = new CorpseCount();
    /** The corpses around, as the test sets them. */
    public int corpses;

    public int getCorpseCount(IsoGameCharacter character) {
        if (character == null) return 0;
        return corpses;
    }
}
