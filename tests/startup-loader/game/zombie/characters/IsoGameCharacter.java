package zombie.characters;

import java.util.ArrayList;
import java.util.EnumMap;
import zombie.ai.State;
import zombie.characterTextures.BloodBodyPartType;
import zombie.characters.BodyDamage.BodyDamage;
import zombie.characters.BodyDamage.BodyPartType;
import zombie.characters.WornItems.WornItems;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.iso.IsoMovingObject;
import zombie.iso.Vector2;

/**
 * Synthetic: the character methods the formulas change, shaped as the game's are (a getter that reads a field, a method
 * that hands its argument on, a getter with a branch, a loop over the inventory, a speed worked out from its parts).
 */
public class IsoGameCharacter extends IsoMovingObject {
    public float clothingDiscomfortModifier = 1f;
    public final Stats stats = new Stats();
    /** What addStiffness added to each part. */
    public final EnumMap<BodyPartType, Float> stiffness = new EnumMap<>(BodyPartType.class);
    public Object thermoregulator;
    public double thermoregulatorFatigue = 1.0;
    public int maxWeight = 20;
    public boolean organized, disorganized;
    public final ItemContainer inventory = new ItemContainer(this);
    private InventoryItem leftHandItem, rightHandItem;
    private WornItems wornItems = new WornItems();
    private float runSpeedModifier = 1f;
    private float fullSpeedMod;
    private float combatSpeedModifier = 1f;
    /** What the last landing made of the load: the first question, and the second when the load is near the most. */
    public final float[] landing = new float[2];
    public float bagsRunModifier = 1f;
    public final BodyDamage bodyDamage = new BodyDamage(this);
    private final FallDamage fallDamage = new FallDamage();
    private State currentState;
    private boolean running;
    /** How much light is on the character (1: all), the multiplier of the worn items on the vision, a ranger's walk through trees. */
    public float luma = 1f, wornVision = 1f;
    public boolean eagleEyed, ranger;
    /** The clothes torn, the scratches of the trees, the speed the last landing was made at, and the damage it did. */
    public int holes, scratches;
    public float landedAt, impactDamage;
    /** Whether the game draws it for each local player, as updateSeenVisibility worked it out. */
    public final boolean[] isVisibleToPlayer = new boolean[4];
    /** Where it looks, whether it sleeps or is dead, and the car it is in. */
    public float lookX = 1f, lookY;
    public boolean asleep, dead;
    public Object vehicle;
    public IsoGameCharacter() { super(); }

    /** How near a player is heard, and the dot of the way to a point with where the character looks, as the game's. */
    public float detectionRange = 3.5f;
    public float getDetectionRange() { return detectionRange; }

    public float getDotWithForwardDirection(float px, float py) {
        float dx = px - x, dy = py - y, length = (float)Math.sqrt(dx * dx + dy * dy), look = (float)Math.sqrt(lookX * lookX + lookY * lookY);
        if (length > 0f) { dx /= length; dy /= length; }
        float ex = look > 0f ? lookX / look : lookX, ey = look > 0f ? lookY / look : lookY;
        return dx * ex + dy * ey;
    }

    public Vector2 getLookVector(Vector2 into) { into.set(lookX, lookY); return into; }

    public boolean isAsleep() { return asleep; }

    public boolean isDead() { return dead; }

    public Object getVehicle() { return vehicle; }

    public BodyDamage getBodyDamage() { return bodyDamage; }

    public float getWornItemsVisionMultiplier() { return wornVision; }

    public State getCurrentState() { return currentState; }

    public boolean isCurrentState(State state) { return currentState == state; }

    public void setCurrentState(State state) { currentState = state; }

    public boolean isRunning() { return running; }

    public void setRunning(boolean value) { running = value; }

    public boolean addHole(BloodBodyPartType part, boolean ripped) {
        holes++;
        return true;
    }

    protected void damageWhileInTrees() {
        scratches++;
        addHole(BloodBodyPartType.Hand_L, true);
    }

    /** A step through the trees that may hurt. */
    public void stepInTrees() { damageWhileInTrees(); }

    /** The character lands at the speed (the game's DoLand): a landing the game counts as a fall is worked out. */
    public void DoLand(float speed) {
        if (!FallingConstants.isFall(speed)) return;
        landedAt = speed;
        fallDamage.setLandingImpact(speed);
        handleLandingImpact(fallDamage);
    }

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

    public InventoryItem getPrimaryHandItem() { return leftHandItem; }
    public InventoryItem getSecondaryHandItem() { return rightHandItem; }
    public void setPrimaryHandItem(InventoryItem item) { leftHandItem = item; }
    public void setSecondaryHandItem(InventoryItem item) { rightHandItem = item; }
    public WornItems getWornItems() { return wornItems; }
    public void setWornItems(WornItems worn) { wornItems = worn; }

    /** Wears the item (the place does not matter here: one place for each). */
    public void wear(InventoryItem item) { wornItems.setItem("place" + item.hashCode(), item); }

    public void takeOff(InventoryItem item) { wornItems.remove(item); }

    public boolean isEquipped(InventoryItem item) {
        return wornItems.contains(item) || (item != null && (leftHandItem == item || rightHandItem == item));
    }

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
        float ratio = damage.getImpactIsoSpeed() / FallingConstants.hardFallThreshold;
        impactDamage = ratio * ratio * 115f;
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
