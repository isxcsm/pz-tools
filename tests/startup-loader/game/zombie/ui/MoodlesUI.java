package zombie.ui;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import zombie.characters.IsoGameCharacter;
import zombie.core.textures.Texture;
import zombie.scripting.objects.MoodleType;
import zombie.scripting.objects.Registries;

/**
 * Synthetic: a player's moodle column, shaped as the game's. It keeps a slot of every type the registry had when it was made; its
 * update places the moodles whose level is above 0 one under the other (wiggling one whose level changed, and asking whether it
 * is good or bad), and its render draws each placed moodle with the picture its texture set has for the type, failing for a
 * type the set has none for, as the game's does.
 */
public final class MoodlesUI {
    public static final float OFFSCREEN = 10000f, DISTANCE = 42f;
    /** The moodle size option, as an index into the sizes. */
    public static int option;
    private final Map<MoodleType, MoodleUIData> moodleUiState = new HashMap<>();
    private final int[] textureSizes = { 32, 48, 64, 80, 96, 128 };
    private final MoodleTextureSet[] textureSets = new MoodleTextureSet[textureSizes.length];
    private MoodleTextureSet currentTextureSet;
    private IsoGameCharacter isoGameCharacter;
    public int numUsedSlots;
    /** What the last render drew: each moodle's type, its picture, and the width and height it was drawn at. */
    public final List<Object[]> drawn = new ArrayList<>();

    public static class MoodleUIData {
        public int goodBadNeutral;
        public int level;
        public float oscillationLevel;
        public float slotsDesiredPos = OFFSCREEN;
        public float slotsPos = OFFSCREEN;
    }

    public MoodlesUI() {
        for (int index = 0; index < textureSizes.length; index++) textureSets[index] = new MoodleTextureSet(textureSizes[index]);
        currentTextureSet = textureSets[0];
        for (MoodleType type : Registries.MOODLE_TYPE.values()) moodleUiState.put(type, new MoodleUIData());
    }

    public void setCharacter(IsoGameCharacter character) {
        isoGameCharacter = character;
        if (character != null && character.getMoodles() != null) character.getMoodles().setMoodlesStateChanged(true);
    }

    public MoodleUIData data(MoodleType type) { return moodleUiState.get(type); }

    public void update() {
        if (isoGameCharacter == null) return;
        if (isoGameCharacter.getMoodles().UI_RefreshNeeded()) {
            int slot = 0;
            for (Map.Entry<MoodleType, MoodleUIData> entry : moodleUiState.entrySet()) {
                MoodleType type = entry.getKey();
                MoodleUIData data = entry.getValue();
                int level = isoGameCharacter.getMoodles().getMoodleLevel(type);
                if (level > 0) {
                    boolean changed = data.level != level;
                    if (changed) { data.level = level; data.oscillationLevel = 1f; }
                    data.slotsDesiredPos = DISTANCE * slot;
                    if (changed) {
                        if (data.slotsPos == OFFSCREEN) data.slotsPos = data.slotsDesiredPos;
                        data.goodBadNeutral = isoGameCharacter.getMoodles().getGoodBadNeutral(type);
                    } else data.oscillationLevel = 0f;
                    slot++;
                    continue;
                }
                data.slotsPos = OFFSCREEN;
                data.slotsDesiredPos = OFFSCREEN;
                data.oscillationLevel = 0f;
                data.level = 0;
            }
            numUsedSlots = slot;
        }
    }

    public void render() {
        currentTextureSet = textureSets[option];
        drawn.clear();
        MoodleTextureSet set = currentTextureSet;
        for (Map.Entry<MoodleType, MoodleUIData> entry : moodleUiState.entrySet()) {
            MoodleType type = entry.getKey();
            if (entry.getValue().slotsPos == OFFSCREEN) continue;
            Texture picture = set.getTexture(type);
            drawn.add(new Object[] { type, picture, picture.getWidth(), picture.getHeight() });
        }
    }
}
