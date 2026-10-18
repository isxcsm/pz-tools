package zombie.core.stash;

import java.util.HashSet;
import java.util.Set;
import zombie.iso.BuildingDef;

/** Synthetic: which buildings hold a stash. */
public final class StashSystem {
    /** Test: the buildings that are a stash's. */
    public static final Set<BuildingDef> stashes = new HashSet<>();
    public static boolean isStashBuilding(BuildingDef building) { return stashes.contains(building); }
}
