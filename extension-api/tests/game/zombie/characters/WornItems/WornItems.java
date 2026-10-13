package zombie.characters.WornItems;

import java.util.ArrayList;
import java.util.List;
import zombie.inventory.InventoryItem;

/** Synthetic: what a character wears, as the game keeps it: a list, one item at each place. */
public final class WornItems {
    private final List<WornItem> items;
    public WornItems() { this.items = new ArrayList<>(); }
    public List<WornItem> getItems() { return items; }
    public int size() { return items.size(); }
    public WornItem get(int index) { return items.get(index); }

    public void setItem(String location, InventoryItem item) {
        for (int index = 0; index < items.size(); index++) if (items.get(index).getLocation().equals(location)) { items.remove(index); break; }
        if (item != null) items.add(new WornItem(location, item));
    }

    public void remove(InventoryItem item) {
        for (int index = 0; index < items.size(); index++) if (items.get(index).getItem() == item) { items.remove(index); return; }
    }

    public void clear() { items.clear(); }

    public boolean contains(InventoryItem item) {
        for (int index = 0; index < items.size(); index++) if (items.get(index).getItem() == item) return true;
        return false;
    }
}
