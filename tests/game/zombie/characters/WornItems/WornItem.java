package zombie.characters.WornItems;

import zombie.inventory.InventoryItem;

/** Synthetic: an item worn at a place of the body. */
public final class WornItem {
    private final String location;
    private final InventoryItem item;
    public WornItem(String location, InventoryItem item) {
        this.location = location;
        this.item = item;
    }
    public String getLocation() { return location; }
    public InventoryItem getItem() { return item; }
}
