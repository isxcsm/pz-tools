package zombie.inventory;

import zombie.iso.IsoObject;

/** Synthetic: like the game's, an appliance has power when its square has, if generators are asked about. */
public final class ItemContainer {
    public static boolean isObjectPowered(IsoObject object, boolean generators) {
        if (object == null || object.getSquare() == null) return false;
        return generators && object.getSquare().haveElectricity();
    }
}
