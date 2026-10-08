package zombie.characters;

import java.util.EnumMap;
import zombie.characters.BodyDamage.BodyPartType;

/**
 * Synthetic: the character methods the formulas change, shaped as the game's are (a getter that reads a field, a method
 * that hands its argument on, a getter with a branch).
 */
public class IsoGameCharacter {
    public float clothingDiscomfortModifier = 1f;
    public final Stats stats = new Stats();
    /** What addStiffness added to each part. */
    public final EnumMap<BodyPartType, Float> stiffness = new EnumMap<>(BodyPartType.class);
    public Object thermoregulator;
    public double thermoregulatorFatigue = 1.0;

    public Stats getStats() { return stats; }

    public float getClothingDiscomfortModifier() { return clothingDiscomfortModifier; }

    public void addStiffness(BodyPartType part, float amount) {
        stiffness.merge(part, amount, Float::sum);
    }

    public double getFatiqueMultiplier() {
        return thermoregulator != null ? thermoregulatorFatigue : 1.0;
    }
}
