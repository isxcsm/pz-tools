package zombie.buildingRooms;

import java.util.ArrayList;
import zombie.iso.BuildingDef;
import zombie.iso.IsoMetaGrid;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;

/**
 * Synthetic: the game's building editor, as setRooms uses it. applyChanges takes the buildings it started from out of
 * the map (a map building's square goes to the removed list), puts its own in, and numbers their rooms anew.
 */
public final class BuildingRoomsEditor {
    private static final BuildingRoomsEditor instance = new BuildingRoomsEditor();
    private final ArrayList<BREBuilding> buildings = new ArrayList<>();
    private final ArrayList<BuildingDef> preEditBuildings = new ArrayList<>();
    private Object luaEditor;
    /** Test: how many times the editor's window was told of a change, which the API must not do. */
    public static int windowCalls;
    private static long nextId = 1000;

    public static BuildingRoomsEditor getInstance() { return instance; }

    public void setLuaEditor(Object editor) { luaEditor = editor; }

    public BREBuilding createBuilding() { var made = new BREBuilding(); buildings.add(made); return made; }

    public BREBuilding copyExistingBuilding(BuildingDef def) { return createBuilding().copyFrom(def); }

    /** Test: the buildings the editor holds, as its window left them. */
    public int pending() { return buildings.size() + preEditBuildings.size(); }

    public void applyChanges(boolean loading) {
        for (BREBuilding building : buildings) if (building.rooms.isEmpty()) return;
        IsoMetaGrid grid = IsoWorld.instance.metaGrid;
        for (BuildingDef def : preEditBuildings) {
            if (!def.isUserDefined()) grid.getRemovedBuildings().add(new RemovedBuilding().setFrom(def));
            grid.rooms.removeAll(def.rooms);
            grid.buildings.remove(def);
        }
        // As the game's: what goes in the map is the building's rooms, its outside squares moved apart.
        for (BREBuilding building : buildings) {
            BuildingDef def = building.buildingDef;
            for (RoomDef room : new ArrayList<>(def.rooms)) {
                room.building = def;
                room.id = nextId++;
                if (room.isEmptyOutside()) { def.rooms.remove(room); def.emptyoutside.add(room); }
                else grid.rooms.add(room);
            }
            grid.buildings.add(def);
        }
        if (luaEditor != null) windowCalls++;
        buildings.clear();
    }
}
