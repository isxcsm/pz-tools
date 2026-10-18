package zombie.iso.objects;

import zombie.iso.IsoObject;
import zombie.iso.sprite.IsoSprite;

/** Synthetic: a door; a double door's half (1 to 4, 0 for a single door) and its other halves; the edge of its square it stands on. */
public final class IsoDoor extends IsoObject {
    public int doubleIndex;
    public final IsoObject[] halves = new IsoObject[5];
    /** As the game's: true on the north edge of its square, false on the west one. */
    public boolean north;
    public IsoDoor(IsoSprite sprite) { super(sprite); }
    public boolean getNorth() { return north; }
    public static int getDoubleDoorIndex(IsoObject door) { return door instanceof IsoDoor d ? d.doubleIndex : -1; }
    public static IsoObject getDoubleDoorObject(IsoObject door, int index) {
        return door instanceof IsoDoor d && index >= 0 && index < d.halves.length ? d.halves[index] : null;
    }
}
