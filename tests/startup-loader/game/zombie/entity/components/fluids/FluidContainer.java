package zombie.entity.components.fluids;

import java.util.LinkedHashMap;
import zombie.entity.Component;

/**
 * Synthetic: what an object holds. {@code amount} is the total, which a test may set; {@code shares} how it divides
 * among fluids (Water unless given). Like the game's, fluid is removed from every fluid in proportion.
 */
public final class FluidContainer extends Component {
    public float amount;
    /** As the game's: a change of the fluid makes the cached amount stale; asking for the amount works it out again. */
    public boolean cacheInvalidated;
    public float amountCache;
    public final float capacity;
    public final LinkedHashMap<Fluid, Float> shares = new LinkedHashMap<>();
    public FluidContainer(float capacity, float amount) { this(capacity, amount, Fluid.Water); }
    public FluidContainer(float capacity, float amount, Fluid fluid) {
        this.capacity = capacity;
        this.amount = amount;
        shares.put(fluid, 1f);
    }
    /** Like the game's: an empty container that holds one litre. */
    public static FluidContainer CreateContainer() { return new FluidContainer(1, 0); }
    public float getAmount() {
        if (cacheInvalidated) {
            amountCache = amount;
            cacheInvalidated = false;
        }
        return amount;
    }
    /** Changes the amount as the game's adjustAmount does: the cache is stale. */
    public void adjustAmount(float change) {
        amount = Math.max(0, Math.min(capacity, amount + change));
        cacheInvalidated = true;
    }
    public float getCapacity() { return capacity; }
    public float getFreeCapacity() { return capacity - amount; }
    public void removeFluid(float used) {
        amount -= Math.max(0, Math.min(used, amount));
        cacheInvalidated = true;
    }
    public boolean isTainted() { return amount > 0 && fluid(Fluid.TaintedWater) > 0; }
    public boolean canAddFluid(Fluid fluid) { return fluid != Fluid.Petrol || amount == 0 || fluid(Fluid.Petrol) == amount; }

    public void addFluid(Fluid fluid, float add) {
        add = Math.min(Math.max(0, add), capacity - amount);
        if (fluid == null || add <= 0 || !canAddFluid(fluid)) return;
        var amounts = new LinkedHashMap<Fluid, Float>();
        for (var share : shares.keySet()) if (fluid(share) > 0) amounts.put(share, fluid(share));
        amounts.merge(fluid, add, Float::sum);
        shares.clear();
        shares.putAll(amounts);
        amount += add;
        cacheInvalidated = true;
    }

    /** The litres of one fluid. */
    public float fluid(Fluid fluid) {
        float total = 0;
        for (float share : shares.values()) total += share;
        Float share = shares.get(fluid);
        return share == null || total <= 0 ? 0 : amount * share / total;
    }

    public FluidSample createFluidSample() { return createFluidSample(amount); }

    public FluidSample createFluidSample(float scale) {
        var sample = new FluidSample();
        for (var fluid : shares.keySet())
            if (fluid(fluid) > 0) sample.fluids.add(new FluidInstance(fluid, amount > 0 ? fluid(fluid) * scale / amount : 0));
        return sample;
    }
}
