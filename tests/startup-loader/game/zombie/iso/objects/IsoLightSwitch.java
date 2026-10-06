package zombie.iso.objects;

import zombie.iso.IsoObject;
import zombie.iso.sprite.IsoSprite;

/** Synthetic. */
public class IsoLightSwitch extends IsoObject {
    public long roomId = -1;
    public IsoLightSwitch(IsoSprite sprite) { super(sprite); powered = true; consumption = 0.002f; }
}
