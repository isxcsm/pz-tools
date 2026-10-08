package zombie.inventory.types;

import java.util.ArrayList;
import zombie.ZomboidGlobals;
import zombie.characters.IsoGameCharacter;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;

/** Synthetic: a bag. Its capacity is its container's, clamped to what a bag can be; worn, it takes weight off its items. */
public class InventoryContainer extends InventoryItem {
    final ItemContainer container;
    private int weightReduction;
    public InventoryContainer(String displayCategory, float actualWeight, int capacity) {
        super(displayCategory, actualWeight);
        container = new ItemContainer(null);
        container.capacity = capacity;
        container.containingItem = this;
        container.inventoryContainer = this;
    }
    public ItemContainer getInventory() { return container; }
    public ItemContainer getItemContainer() { return container; }
    public int getWeightReduction() { return weightReduction; }
    public void setWeightReduction(int reduction) { weightReduction = reduction; }
    public ArrayList<InventoryItem> getItems() { return container.getItems(); }

    public int getCapacity() {
        int capacity = container.getCapacity();
        if (capacity > 50.0f - actualWeight) capacity = (int)(50.0f - actualWeight);
        return capacity;
    }

    public int getEffectiveCapacity(IsoGameCharacter character) {
        int capacity = container.getEffectiveCapacity(character);
        if (capacity > 50.0f - actualWeight) capacity = (int)(50.0f - actualWeight);
        return capacity;
    }

    @Override public float getContentsWeight() { return container.getContentsWeight(); }

    @Override public float getEquippedWeight() {
        float kept = 1.0f;
        if (getWeightReduction() > 0) kept = 1.0f - getWeightReduction() / 100.0f;
        return getActualWeight() * (float)ZomboidGlobals.equippedOrWornEncumbranceMultiplier + getContentsWeight() * kept;
    }
}
