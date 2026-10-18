package zombie.iso.areas;

import zombie.iso.BuildingDef;

/** Synthetic: the building a loaded square is in, and the map building it was made from. */
public final class IsoBuilding {
    public BuildingDef def;
    public IsoBuilding() { }
    public IsoBuilding(BuildingDef def) { this.def = def; }
    public BuildingDef getDef() { return def; }
}
