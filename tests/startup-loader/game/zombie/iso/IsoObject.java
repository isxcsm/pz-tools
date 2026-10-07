package zombie.iso;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import zombie.entity.components.fluids.FluidContainer;
import zombie.iso.sprite.IsoSprite;

/**
 * Synthetic: what the game says about an object's power use comes from the object. Its water questions branch on
 * {@code usesExternalWaterSource} as the game's do: a piped fixture answers with its source's water.
 */
public class IsoObject {
    public IsoSprite sprite;
    public IsoGridSquare square;
    public boolean powered;
    public float consumption;
    public int electricityChecks;
    /** The other parts of an object that covers several squares. */
    public final ArrayList<IsoObject> gridParts = new ArrayList<>();
    public boolean usesExternalWaterSource;
    public IsoObject externalWaterSource;
    public FluidContainer fluidContainer;
    public IsoObject(IsoSprite sprite) { this.sprite = sprite; }
    public IsoSprite getSprite() { return sprite; }
    public String getSpriteName() { return null; }
    public IsoGridSquare getSquare() { return square; }
    public boolean couldBePoweredByGenerator() { return powered; }
    public float getGeneratorPowerConsumption() { return consumption; }
    public void checkHaveElectricity() { electricityChecks++; }
    public FluidContainer getFluidContainer() { return fluidContainer; }
    public boolean getUsesExternalWaterSource() { return usesExternalWaterSource; }

    private IsoObject checkExternalFluidSource() {
        if (!usesExternalWaterSource) return null;
        return externalWaterSource;
    }

    public float getFluidAmount() {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            return source == null ? 0 : source.getFluidAmount();
        }
        return fluidContainer == null ? 0 : fluidContainer.getAmount();
    }

    public float getFluidCapacity() {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            return source == null ? 0 : source.getFluidCapacity();
        }
        return fluidContainer == null ? 0 : fluidContainer.getCapacity();
    }

    public float useFluid(float amount) {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            return source == null ? 0 : source.useFluid(amount);
        }
        if (fluidContainer == null) return 0;
        float used = Math.min(amount, fluidContainer.getAmount());
        fluidContainer.removeFluid(used);
        return used;
    }

    /** What the world keeps: the game's own flag. */
    public void save(ByteBuffer output, boolean network) { output.put((byte)(usesExternalWaterSource ? 1 : 0)); }

    public boolean hasSpriteGrid() { return !gridParts.isEmpty(); }
    public ArrayList<IsoObject> getSpriteGridObjectsIncludingSelf(ArrayList<IsoObject> result) {
        result.clear();
        result.add(this);
        result.addAll(gridParts);
        return result;
    }
}
