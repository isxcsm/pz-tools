package zombie.buildingRooms;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.function.Consumer;
import zombie.iso.BuildingDef;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoMetaCell;
import zombie.iso.IsoMetaGrid;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;

/**
 * Synthetic: the game's building editor, as setRooms uses it. applyChanges takes the buildings it started from out of
 * the map (a map building's square goes to the removed list), puts its own in, numbers their rooms anew; and, as the game's
 * does, numbers every cell's buildings and rooms again, checks their numbers three times and works out every loaded square again.
 */
public final class BuildingRoomsEditor {
    private static final BuildingRoomsEditor instance = new BuildingRoomsEditor();
    private final ArrayList<BREBuilding> buildings = new ArrayList<>();
    private final ArrayList<BuildingDef> preEditBuildings = new ArrayList<>();
    private Object luaEditor;
    /** Test: how many times the editor's window was told of a change, which the API must not do. */
    public static int windowCalls;
    private static long nextId = 1000;
    /** Test: the squares the last changes worked out again, the cells numbered again one by one, and the passes over every cell. */
    public static final Set<IsoGridSquare> updated = new HashSet<>();
    public static final Set<IsoMetaCell> renumbered = new HashSet<>();
    public static int everyCell;

    public static BuildingRoomsEditor getInstance() { return instance; }

    public void setLuaEditor(Object editor) { luaEditor = editor; }

    public BREBuilding createBuilding() { var made = new BREBuilding(); buildings.add(made); return made; }

    public BREBuilding copyExistingBuilding(BuildingDef def) { return createBuilding().copyFrom(def); }

    /** Test: the buildings the editor holds, as its window left them. */
    public int pending() { return buildings.size() + preEditBuildings.size(); }

    /** Test: the building the last load made from the rooms file it read. */
    public static BREBuilding lastLoaded;

    /** As the game's, as the world loads: reads the rooms file, and makes the editor's building for what it gave. */
    public void load() {
        new PlayerRoomsFile().load();
        lastLoaded = new BREBuilding();
    }

    public void applyChanges(boolean loading) {
        for (BREBuilding building : buildings) if (building.rooms.isEmpty()) return;
        updated.clear();
        renumbered.clear();
        everyCell = 0;
        checkBuildingAndRoomIDs();
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
        checkBuildingAndRoomIDs();
        recalculateBuildingAndRoomIDs();
        checkBuildingAndRoomIDs();
        zombie.iso.LightingJNI.buildingsChanged();
        updateSquares();
        if (luaEditor != null) windowCalls++;
        buildings.clear();
    }

    /** As the game's: a check of the numbers of every cell's buildings and rooms, which only logs. */
    public void checkBuildingAndRoomIDs() { everyCell++; }

    /** As the game's: every cell's buildings and rooms numbered again, one by one. */
    private void recalculateBuildingAndRoomIDs() {
        everyCell++;
        IsoMetaGrid grid = IsoWorld.instance.metaGrid;
        for (int x = grid.minX; x <= grid.maxX; x++)
            for (int y = grid.minY; y <= grid.maxY; y++) {
                IsoMetaCell cell = grid.getCellData(x, y);
                if (cell != null) recalculateBuildingAndRoomIDs(cell);
            }
    }

    void recalculateBuildingAndRoomIDs(IsoMetaCell cell) { renumbered.add(cell); }

    /** As the game's: every loaded square's room, then its properties, each a pass over them all. */
    private void updateSquares() {
        forEachSquare(updated::add);
        forEachSquare(updated::add);
    }

    private void forEachSquare(Consumer<IsoGridSquare> work) {
        for (IsoGridSquare square : IsoWorld.instance.currentCell.squares.values()) work.accept(square);
    }
}
