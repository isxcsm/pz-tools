package zombie.inventory.types;

import zombie.GameTime;
import zombie.SandboxOptions;
import zombie.inventory.ItemContainer;

/**
 * Synthetic: like the game's, food ages over the hours since it last aged. In a fridge or freezer they count at the
 * fridge factor when its square has power now, and are split only at the grid's shut-off.
 */
public class Food {
    public ItemContainer container;
    public boolean chilled, frozen;
    public float age;
    private float lastAged;
    public Food(ItemContainer container) { this.container = container; }
    public ItemContainer getOutermostContainer() { return container; }
    public boolean isFrozen() { return frozen; }
    public float getFoodRotSpeed() { return 1; }
    private float getFridgeFactor() { return 0.2f; }
    public float getLastAged() { return lastAged; }
    public void setLastAged(float hours) { lastAged = hours; }

    public void updateAge(boolean unused) {
        float now = (float)GameTime.getInstance().getWorldAgeHours();
        ItemContainer outer = getOutermostContainer();
        chilled = outer != null && outer.getSourceGrid() != null && outer.getSourceGrid().haveElectricity();
        if (now <= lastAged) return;
        double hours = now - lastAged;
        if (isFrozen()) hours = 0;
        else if (outer != null && (outer.isFridge() || outer.isFreezer())) {
            int shut = SandboxOptions.instance.getElecShutModifier();
            if (chilled) hours *= getFridgeFactor();
            else if (shut > -1 && lastAged < shut * 24) {
                hours = (Math.min(now, shut * 24) - lastAged) * getFridgeFactor();
                if (now > shut * 24) hours += now - shut * 24;
            }
        }
        age = (float)(age + hours * getFoodRotSpeed() / 24.0);
        lastAged = now;
    }
}
