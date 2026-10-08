package zombie.entity.components.fluids;

import java.util.HashMap;

/** Synthetic: the game's fluids, by name. */
public final class Fluid {
    private static final HashMap<String, Fluid> byName = new HashMap<>();
    public static final Fluid Water = new Fluid("Water"), TaintedWater = new Fluid("TaintedWater"), Petrol = new Fluid("Petrol");
    private final String name;
    private Fluid(String name) { this.name = name; byName.put(name, this); }
    public static Fluid Get(String name) { return byName.get(name); }
    public String getFluidTypeString() { return name; }
    @Override public String toString() { return name; }
}
