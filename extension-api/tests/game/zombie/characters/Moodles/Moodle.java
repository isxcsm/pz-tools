package zombie.characters.Moodles;

import zombie.characters.IsoGameCharacter;
import zombie.scripting.objects.MoodleType;

/**
 * Synthetic: a character's moodle of one type, shaped as the game's. Its update works out the level of the game's types (here the
 * heavy load, which asks how heavily the character is loaded), and a type it does not know falls through to level 0; the level
 * goes through updateMoodleLevel, which says whether it changed.
 */
public final class Moodle {
    private final MoodleType moodleType;
    private int moodleLevel;
    private final IsoGameCharacter isoGameCharacter;
    /** The load over the most the character can carry, as the last update saw it. */
    public float ratio;
    /** How many times the update worked a level out itself (the game's own path). */
    public static int worked;

    public Moodle(MoodleType moodleType, IsoGameCharacter isoGameCharacter) {
        this.isoGameCharacter = isoGameCharacter;
        this.moodleType = moodleType;
    }

    /** The heavy load moodle of the character. */
    public Moodle(IsoGameCharacter character) { this(MoodleType.HEAVY_LOAD, character); }

    public MoodleType getMoodleType() { return moodleType; }

    public int getLevel() { return moodleLevel; }

    private boolean updateMoodleLevel(int level) {
        if (level == moodleLevel) return false;
        moodleLevel = Math.max(0, Math.min(level, 4));
        return true;
    }

    public boolean Update() {
        worked++;
        int level = 0;
        if (isoGameCharacter.isDead() && moodleType != MoodleType.DEAD && moodleType != MoodleType.ZOMBIE) return updateMoodleLevel(level);
        if (moodleType == MoodleType.HEAVY_LOAD) {
            float load = isoGameCharacter.getInventory().getCapacityWeight();
            float max = isoGameCharacter.getMaxWeight();
            ratio = load / max;
            if (ratio > 1f) level = Math.min(4, (int)ratio);
        }
        return updateMoodleLevel(level);
    }
}
