package zombie.entity.components.crafting.recipe;

import java.util.ArrayList;
import java.util.function.Consumer;
import zombie.characters.IsoGameCharacter;
import zombie.inventory.InventoryItem;

/**
 * Synthetic: a craft as the game hands it to the recipe's OnCreate: the items it made and the ones it used up, and the
 * OnCreate itself (a refill that reads the made item, as the game's Java OnCreates do).
 */
public class CraftRecipeData {
    public final ArrayList<InventoryItem> created = new ArrayList<>(), consumed = new ArrayList<>();
    public Consumer<CraftRecipeData> onCreate;

    public ArrayList<InventoryItem> getAllCreatedItems() { return created; }
    public ArrayList<InventoryItem> getAllConsumedItems() { return consumed; }

    public void luaCallOnCreate(IsoGameCharacter character) {
        if (onCreate != null) onCreate.accept(this);
    }
}
