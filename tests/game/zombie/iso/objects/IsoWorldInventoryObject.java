package zombie.iso.objects;

import zombie.inventory.InventoryItem;
import zombie.iso.IsoObject;

/** Synthetic: an item lying on the floor, with the game's flag that keeps it from the sandbox's world item removal. */
public final class IsoWorldInventoryObject extends IsoObject {
    private final InventoryItem item;
    private boolean ignoreRemoveSandbox;

    public IsoWorldInventoryObject(InventoryItem item) {
        super(null);
        this.item = item;
    }

    public InventoryItem getItem() { return item; }
    public boolean isIgnoreRemoveSandbox() { return ignoreRemoveSandbox; }
    public void setIgnoreRemoveSandbox(boolean value) { ignoreRemoveSandbox = value; }
}
