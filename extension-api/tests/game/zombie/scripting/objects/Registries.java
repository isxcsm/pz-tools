package zombie.scripting.objects;

/** Synthetic: the game's registries; the moodle types register themselves as their class loads. */
public class Registries {
    public static final Registry<MoodleType> MOODLE_TYPE = new Registry<>("moodle_type");

    static { MoodleType.bootstrap(); }
}
