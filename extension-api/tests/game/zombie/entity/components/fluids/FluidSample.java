package zombie.entity.components.fluids;

import java.util.ArrayList;

/** Synthetic: a copy of what a container holds, fluid by fluid. */
public final class FluidSample {
    final ArrayList<FluidInstance> fluids = new ArrayList<>();
    public int size() { return fluids.size(); }
    public Fluid getFluid(int index) { return fluids.get(index).getFluid(); }
    public FluidInstance getFluidInstance(int index) { return fluids.get(index); }
    public void release() { fluids.clear(); }
}
