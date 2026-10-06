package zombie.inventory.types;

import zombie.inventory.ItemContainer;

/** Synthetic: like the game's, food in a container ages as chilled while the container's square has power. */
public class Food {
    public ItemContainer container;
    public boolean chilled;
    public Food(ItemContainer container) { this.container = container; }
    public void updateAge(boolean unused) {
        chilled = container != null && container.getSourceGrid() != null && container.getSourceGrid().haveElectricity();
    }
}
