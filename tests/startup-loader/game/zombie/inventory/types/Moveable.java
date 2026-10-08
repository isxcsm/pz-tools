package zombie.inventory.types;

import zombie.inventory.InventoryItem;

/** Synthetic: a piece of furniture picked up, which takes its weight and name from the sprite it was read from. */
public class Moveable extends InventoryItem {
    public Moveable() { super("Moveable", 1f); }
    public void readFromWorldSprite(float weight, String sprite) {
        actualWeight = weight;
        name = sprite;
        fullType = "Base." + sprite;
    }
}
