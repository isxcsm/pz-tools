package zombie.inventory.types;

import zombie.inventory.InventoryItem;

/**
 * Synthetic: a drainable (a torch, a battery), as the game's keeps its uses: a whole count, and a use delta of its own that
 * shadows the item's. Its methods read the delta as the game's do.
 */
public class DrainableComboItem extends InventoryItem {
    private float useDelta;
    private int uses;

    public DrainableComboItem(String category, float weight, float useDelta, int uses) {
        super(category, weight);
        this.useDelta = useDelta;
        this.uses = uses;
    }

    public int getMaxUses() { return Math.round(1f / useDelta); }
    @Override public float getUseDelta() { return useDelta; }
    public float getCurrentUsesFloat() { return uses * useDelta; }
    public void setCurrentUsesFloat(float fraction) { uses = Math.round(fraction / useDelta); }
    public int getCurrentUses() { return uses; }
    public void setCurrentUses(int value) { uses = value; }
}
