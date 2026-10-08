package zombie.characters;

import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HashSet;
import java.util.Set;
import zombie.characters.BodyDamage.BodyPartType;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.iso.IsoObject;

/**
 * Synthetic: the character methods the formulas change, shaped as the game's are (a getter that reads a field, a method
 * that hands its argument on, a getter with a branch, a loop over the inventory, a speed worked out from its parts).
 */
public class IsoGameCharacter extends IsoObject {
    public float clothingDiscomfortModifier = 1f;
    public final Stats stats = new Stats();
    /** What addStiffness added to each part. */
    public final EnumMap<BodyPartType, Float> stiffness = new EnumMap<>(BodyPartType.class);
    public Object thermoregulator;
    public double thermoregulatorFatigue = 1.0;
    public int maxWeight = 20;
    public boolean organized, disorganized;
    public final ItemContainer inventory = new ItemContainer(this);
    public final Set<InventoryItem> equipped = new HashSet<>();
    private float runSpeedModifier = 1f;
    private float fullSpeedMod;
    private float combatSpeedModifier = 1f;
    /** What the last landing made of the load: the first question, and the second when the load is near the most. */
    public final float[] landing = new float[2];
    public float bagsRunModifier = 1f;
    public IsoGameCharacter() { super(null); }

    public Stats getStats() { return stats; }

    public float getClothingDiscomfortModifier() { return clothingDiscomfortModifier; }

    public void addStiffness(BodyPartType part, float amount) {
        stiffness.merge(part, amount, Float::sum);
    }

    public double getFatiqueMultiplier() {
        return thermoregulator != null ? thermoregulatorFatigue : 1.0;
    }

    public ItemContainer getInventory() { return inventory; }

    public int getMaxWeight() { return maxWeight; }

    public boolean isEquipped(InventoryItem item) { return equipped.contains(item); }

    public float getInventoryWeight() {
        if (getInventory() == null) return 0.0f;
        float total = 0.0f;
        ArrayList<InventoryItem> list = getInventory().getItems();
        for (int index = 0; index < list.size(); index++) {
            InventoryItem item = list.get(index);
            if (item.getAttachedSlot() > -1 && !isEquipped(item)) total += item.getHotbarEquippedWeight();
            else if (!isEquipped(item) && !item.isFakeEquipped(this)) total += item.getUnequippedWeight();
            else total += item.getEquippedWeight();
        }
        return total;
    }

    /** Three questions about the load, as the fall damage asks them (the third only near the most). */
    protected void handleLandingImpact(FallDamage damage) {
        landing[0] = getInventory().getCapacityWeight() / getInventory().getMaxWeight();
        if (getInventory().getMaxWeight() - getInventory().getCapacityWeight() < 2.0f)
            landing[1] = getInventory().getCapacityWeight() / getInventory().getMaxWeight() * 20.0f;
    }

    public void landing() { handleLandingImpact(new FallDamage()); }

    /** The speed from the penalties: the full speed modifier is stored. */
    public float calculateBaseSpeed() {
        float base = 0.8f;
        fullSpeedMod = runSpeedModifier + (bagsRunModifier - 1.0f);
        return base * (1.0f - Math.abs(1.0f - fullSpeedMod) / 2.0f);
    }

    public float fullSpeedMod() { return fullSpeedMod; }

    public void setRunSpeedModifier(float modifier) { runSpeedModifier = modifier; }

    public void setCombatSpeedModifier(float modifier) { combatSpeedModifier = modifier; }

    /** The combat speed: the equipment's modifier is read once. */
    public float calculateCombatSpeed() {
        float speed = 1.0f;
        speed = speed * combatSpeedModifier;
        return Math.max(0.8f, Math.min(1.6f, speed));
    }
}
