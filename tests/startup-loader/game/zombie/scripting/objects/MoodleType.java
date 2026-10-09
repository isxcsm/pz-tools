package zombie.scripting.objects;

/** Synthetic: the game's moodle types, registered objects (some of the game's), and register(id) for a mod's, as the game's. */
public class MoodleType {
    public static final MoodleType ENDURANCE = registerBase("Endurance");
    public static final MoodleType HUNGRY = registerBase("Hungry");
    public static final MoodleType HEAVY_LOAD = registerBase("HeavyLoad");
    public static final MoodleType DEAD = registerBase("Dead");
    public static final MoodleType ZOMBIE = registerBase("Zombie");
    public static final MoodleType FOOD_EATEN = registerBase("FoodEaten");
    private final String translationName;

    private MoodleType(String translationName) { this.translationName = translationName; }

    static void bootstrap() { }

    public static MoodleType get(ResourceLocation id) { return Registries.MOODLE_TYPE.get(id); }

    @Override public String toString() { return Registries.MOODLE_TYPE.getLocation(this).toString(); }

    public String getTranslationName() { return translationName; }

    public static MoodleType register(String id) { return register(false, id); }

    private static MoodleType registerBase(String id) { return register(true, id); }

    private static MoodleType register(boolean allowDefaultNamespace, String id) {
        return Registries.MOODLE_TYPE.register(RegistryReset.createLocation(id, allowDefaultNamespace), new MoodleType(id));
    }
}
