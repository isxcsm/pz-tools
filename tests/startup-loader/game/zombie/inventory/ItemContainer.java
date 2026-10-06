package zombie.inventory;

import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;

/** Synthetic: like the game's, an appliance has power when its square has, if generators are asked about. */
public final class ItemContainer {
    public IsoObject parent;
    public ItemContainer(IsoObject parent) { this.parent = parent; }
    public IsoObject getParent() { return parent; }
    public IsoGridSquare getSourceGrid() { return parent == null ? null : parent.getSquare(); }
    public static boolean isObjectPowered(IsoObject object, boolean generators) {
        if (object == null || object.getSquare() == null) return false;
        return generators && object.getSquare().haveElectricity();
    }
}
