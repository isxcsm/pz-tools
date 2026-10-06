package zombie.iso;

import java.util.ArrayList;
import zombie.iso.sprite.IsoSprite;

/** Synthetic: what the game says about an object's power use comes from the object. */
public class IsoObject {
    public IsoSprite sprite;
    public IsoGridSquare square;
    public boolean powered;
    public float consumption;
    public int electricityChecks;
    /** The other parts of an object that covers several squares. */
    public final ArrayList<IsoObject> gridParts = new ArrayList<>();
    public IsoObject(IsoSprite sprite) { this.sprite = sprite; }
    public IsoSprite getSprite() { return sprite; }
    public String getSpriteName() { return null; }
    public IsoGridSquare getSquare() { return square; }
    public boolean couldBePoweredByGenerator() { return powered; }
    public float getGeneratorPowerConsumption() { return consumption; }
    public void checkHaveElectricity() { electricityChecks++; }
    public boolean hasSpriteGrid() { return !gridParts.isEmpty(); }
    public ArrayList<IsoObject> getSpriteGridObjectsIncludingSelf(ArrayList<IsoObject> result) {
        result.clear();
        result.add(this);
        result.addAll(gridParts);
        return result;
    }
}
