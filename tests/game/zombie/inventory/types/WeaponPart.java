package zombie.inventory.types;

import zombie.inventory.InventoryItem;

/** Synthetic: a part of a weapon, which adds its weight modifier to the weapon's. */
public class WeaponPart extends InventoryItem {
    public float weightModifier;
    public WeaponPart(float weightModifier) {
        super("WeaponPart", 0.1f);
        this.weightModifier = weightModifier;
    }
}
