package zombie.vehicles;

import java.util.HashMap;
import java.util.Map;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.inventory.InventoryItem;

/**
 * Synthetic: a part of a vehicle, which has modData and may hold a container; its id, condition, item (the part's
 * stats follow the item's as the game's do: the count of calls here), wheel and the models it shows.
 */
public final class VehiclePart {
    private KahluaTable modData;
    public String id;
    public int condition, wheel = -1, statsDone, installer;
    public InventoryItem item;
    public final Map<String, Boolean> models = new HashMap<>();
    public boolean hasModData() { return modData != null; }
    public KahluaTable getModData() {
        if (modData == null) modData = LuaManager.platform.newTable();
        return modData;
    }
    public String getId() { return id; }
    public int getCondition() { return condition; }
    public void setCondition(int value) { condition = Math.max(0, Math.min(100, value)); }
    public InventoryItem getInventoryItem() { return item; }
    public void setInventoryItem(InventoryItem value) { item = value; }
    public void doInventoryItemStats(InventoryItem value, int skill) { statsDone++; }
    public int getMechanicSkillInstaller() { return installer; }
    public int getWheelIndex() { return wheel; }
    public void setModelVisible(String model, boolean visible) { models.put(model, visible); }
}
