package zombie.inventory.types;

import zombie.characters.IsoPlayer;
import zombie.inventory.InventoryItem;

/** Synthetic: a piece of clothing, whose name says when it is bloody, as the game's does (the field read, then dressed). */
public class Clothing extends InventoryItem {
    public boolean bloody;

    public Clothing() { super("Clothing", 0.5f); }

    @Override public String getName(IsoPlayer player) { return bloody ? name + " (Bloody)" : name; }
}
