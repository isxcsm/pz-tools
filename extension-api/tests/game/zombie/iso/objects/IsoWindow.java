package zombie.iso.objects;

import zombie.iso.IsoObject;
import zombie.iso.sprite.IsoSprite;

/** Synthetic: a window; on the north edge of its square, or the west. */
public class IsoWindow extends IsoObject {
    public boolean north;
    public IsoWindow(IsoSprite sprite) { super(sprite); }
    public boolean getNorth() { return north; }
}
