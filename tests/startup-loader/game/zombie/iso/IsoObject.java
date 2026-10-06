package zombie.iso;

import zombie.iso.sprite.IsoSprite;

/** Synthetic: what the game says about an object's power use comes from the object. */
public class IsoObject {
    public IsoSprite sprite;
    public boolean powered;
    public float consumption;
    public IsoObject(IsoSprite sprite) { this.sprite = sprite; }
    public IsoSprite getSprite() { return sprite; }
    public String getSpriteName() { return null; }
    public boolean couldBePoweredByGenerator() { return powered; }
    public float getGeneratorPowerConsumption() { return consumption; }
}
