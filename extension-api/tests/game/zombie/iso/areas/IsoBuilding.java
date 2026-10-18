package zombie.iso.areas;

import zombie.iso.BuildingDef;

/** Synthetic: the game's building of a map building's rooms. */
public final class IsoBuilding {
    public BuildingDef def;
    public IsoBuilding(BuildingDef def) { this.def = def; }
    public BuildingDef getDef() { return def; }
}
