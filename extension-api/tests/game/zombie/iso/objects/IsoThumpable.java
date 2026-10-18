package zombie.iso.objects;

import zombie.iso.IsoObject;
import zombie.iso.sprite.IsoSprite;

/** Synthetic: an object a player built; a door when a test says so, on the north or west edge of its square. */
public class IsoThumpable extends IsoObject {
    private boolean isDoor;
    public boolean north;
    public IsoThumpable(IsoSprite sprite) { super(sprite); }
    public boolean isDoor() { return isDoor; }
    public void setIsDoor(boolean value) { isDoor = value; }
    public boolean getNorth() { return north; }
}
