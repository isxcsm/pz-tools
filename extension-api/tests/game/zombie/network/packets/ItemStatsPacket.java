package zombie.network.packets;

import java.util.ArrayList;
import zombie.inventory.types.Food;

/** Synthetic: the stats of an item a server sends, applied to the item (here, a food's extra items). */
public class ItemStatsPacket {
    public void apply(Food food, ArrayList<String> extraItems) { food.extraItems = extraItems; }
}
