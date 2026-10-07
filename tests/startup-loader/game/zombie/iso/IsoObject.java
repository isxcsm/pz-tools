package zombie.iso;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.entity.components.fluids.Fluid;
import zombie.entity.components.fluids.FluidContainer;
import zombie.entity.components.fluids.FluidSample;
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
    public KahluaTable modData;
    public int syncs;
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

    /** Like the game's: a piped fixture's water comes through a sample of its source, purified. */
    public float transferFluidTo(FluidContainer target, float amount) {
        if (!usesExternalWaterSource) return 0;
        IsoObject source = checkExternalFluidSource();
        if (source == null || source.fluidContainer == null) return 0;
        float used = Math.max(0, Math.min(amount, Math.min(target.getFreeCapacity(), source.getFluidAmount())));
        FluidContainer sample = createSampleAndPurifyWater(source.fluidContainer, used);
        FluidSample fluids = sample.createFluidSample();
        for (int index = 0; index < fluids.size(); index++) target.addFluid(fluids.getFluid(index), fluids.getFluidInstance(index).getAmount());
        source.fluidContainer.removeFluid(used);
        return used;
    }

    // Reassigns its argument, as the game's does.
    private FluidContainer createSampleAndPurifyWater(FluidContainer source, float amount) {
        FluidContainer sample = FluidContainer.CreateContainer();
        if (source != null) {
            amount = Math.max(0, Math.min(amount, source.getAmount()));
            FluidSample fluids = source.createFluidSample(1);
            for (int index = 0; index < fluids.size(); index++) {
                Fluid fluid = fluids.getFluid(index) == Fluid.TaintedWater ? Fluid.Water : fluids.getFluid(index);
                sample.addFluid(fluid, amount * fluids.getFluidInstance(index).getAmount());
            }
        }
        return sample;
    }

    /** Like the game's: a piped fixture's water is clean while its source holds some. */
    public boolean isTaintedWater() {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            if (source == null) return false;
            if (source.fluidContainer != null && source.fluidContainer.getAmount() > 0) return false;
            return source.isTaintedWater();
        }
        return fluidContainer != null && fluidContainer.isTainted();
    }

    public KahluaTable getModData() {
        if (modData == null) modData = LuaManager.platform.newTable();
        return modData;
    }

    /** The game sends the object to multiplayer clients. */
    public void sync() { syncs++; }

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
