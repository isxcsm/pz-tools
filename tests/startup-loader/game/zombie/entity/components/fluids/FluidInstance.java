package zombie.entity.components.fluids;

/** Synthetic: an amount of one fluid. */
public final class FluidInstance {
    private final Fluid fluid;
    private final float amount;
    FluidInstance(Fluid fluid, float amount) { this.fluid = fluid; this.amount = amount; }
    public Fluid getFluid() { return fluid; }
    public float getAmount() { return amount; }
}
