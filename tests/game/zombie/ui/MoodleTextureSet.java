package zombie.ui;

import java.util.HashMap;
import java.util.Map;
import zombie.core.textures.Texture;
import zombie.scripting.objects.MoodleType;

/** Synthetic: the pictures of the game's own moodle types at one size, as the game's set holds them; none for any other type. */
public final class MoodleTextureSet {
    private final int size;
    private final Texture border, background;
    private final Map<MoodleType, Texture> moodleTextures = new HashMap<>();

    public MoodleTextureSet(int size) {
        this.size = size;
        String dir = "media/ui/Moodles/" + size;
        border = new Texture(dir + "/_Moodles_BGoutline.png", size, size);
        background = new Texture(dir + "/_Moodles_BGsolid.png", size, size);
        moodleTextures.put(MoodleType.ENDURANCE, new Texture(dir + "/Status_DifficultyBreathing.png", size, size));
        moodleTextures.put(MoodleType.HUNGRY, new Texture(dir + "/Status_Hunger.png", size, size));
        moodleTextures.put(MoodleType.HEAVY_LOAD, new Texture(dir + "/Status_HeavyLoad.png", size, size));
        moodleTextures.put(MoodleType.DEAD, new Texture(dir + "/Mood_Dead.png", size, size));
        moodleTextures.put(MoodleType.ZOMBIE, new Texture(dir + "/Mood_Zombified.png", size, size));
        moodleTextures.put(MoodleType.FOOD_EATEN, new Texture(dir + "/Status_Hunger.png", size, size));
    }

    public Texture getTexture(MoodleType type) { return moodleTextures.get(type); }
    public Texture getBorder() { return border; }
    public Texture getBackground() { return background; }
    public int getSize() { return size; }
}
