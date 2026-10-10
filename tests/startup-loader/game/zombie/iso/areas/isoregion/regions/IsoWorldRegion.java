package zombie.iso.areas.isoregion.regions;

import java.util.ArrayList;

/** Synthetic: a region of squares that walls close off, with what roofs it and the regions doors and windows join it to. */
public final class IsoWorldRegion {
    public boolean enclosed;
    public float roofed;
    public final ArrayList<IsoWorldRegion> joined = new ArrayList<>();

    public IsoWorldRegion(boolean enclosed, float roofed) { this.enclosed = enclosed; this.roofed = roofed; }

    public boolean isEnclosed() { return enclosed; }
    public float getRoofedPercentage() { return roofed; }
    public ArrayList<IsoWorldRegion> getDebugConnectedNeighborCopy() { return new ArrayList<>(joined); }
}
