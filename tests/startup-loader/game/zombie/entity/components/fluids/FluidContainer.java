package zombie.entity.components.fluids;

/** Synthetic: what an object holds. */
public final class FluidContainer {
    public float amount;
    public final float capacity;
    public FluidContainer(float capacity, float amount) { this.capacity = capacity; this.amount = amount; }
    public float getAmount() { return amount; }
    public float getCapacity() { return capacity; }
    public void removeFluid(float used) { amount -= used; }
}
