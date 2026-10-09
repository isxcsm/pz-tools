package zombie.characters.Moodles;

import java.util.HashMap;
import java.util.Map;
import zombie.characters.IsoGameCharacter;
import zombie.scripting.objects.MoodleType;
import zombie.scripting.objects.Registries;

/** Synthetic: a character's moodles, one of every type the registry had when they were made, shaped as the game's. */
public class Moodles {
    private boolean moodlesStateChanged;
    private final Map<MoodleType, Moodle> moodles = new HashMap<>();

    public Moodles(IsoGameCharacter parent) {
        for (MoodleType type : Registries.MOODLE_TYPE.values()) moodles.put(type, new Moodle(type, parent));
    }

    public int getGoodBadNeutral(MoodleType type) { return GoodBadNeutral(type); }

    /** The key of the text the column shows for the moodle (the game asks the Translator with it). */
    public String getMoodleDisplayString(MoodleType type) {
        return "Moodles_" + type.getTranslationName() + "_lvl" + moodles.get(type).getLevel();
    }

    public int getMoodleLevel(MoodleType type) { return moodles.get(type).getLevel(); }

    public boolean UI_RefreshNeeded() {
        if (!moodlesStateChanged) return false;
        moodlesStateChanged = false;
        return true;
    }

    public void setMoodlesStateChanged(boolean refresh) { moodlesStateChanged = refresh; }

    public void Update() {
        for (Moodle moodle : moodles.values()) if (moodle.Update()) moodlesStateChanged = true;
    }

    private int GoodBadNeutral(MoodleType type) {
        if (type == MoodleType.FOOD_EATEN) return 1;
        return 2;
    }
}
