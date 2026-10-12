package zombie.characters;

/** Synthetic: the game's stats are constants of a class, not an enum. */
public class CharacterStat {
    public static final CharacterStat ENDURANCE = new CharacterStat("endurance", 0f, 1f);
    public static final CharacterStat POISON = new CharacterStat("poison", 0f, 100f);
    public static final CharacterStat HUNGER = new CharacterStat("hunger", 0f, 1f);
    private final String id;
    private final float minimum, maximum;
    private CharacterStat(String id, float minimum, float maximum) { this.id = id; this.minimum = minimum; this.maximum = maximum; }
    public float clamp(float value) { return Math.max(minimum, Math.min(maximum, value)); }
    public String getId() { return id; }
}
