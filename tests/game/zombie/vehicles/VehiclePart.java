package zombie.vehicles;

import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;

/** Synthetic: a part of a vehicle, which has modData and may hold a container. */
public final class VehiclePart {
    private KahluaTable modData;
    public boolean hasModData() { return modData != null; }
    public KahluaTable getModData() {
        if (modData == null) modData = LuaManager.platform.newTable();
        return modData;
    }
}
