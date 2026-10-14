package zombie.buildingRooms;

import java.util.ArrayList;
import zombie.iso.BuildingDef;
import zombie.iso.RoomDef;

/**
 * Synthetic: a building of the editor. As the game's, it makes its building one players built (the API's hook makes it a
 * map building), and its calls keep the building's rooms with its own: the building's are what the editor puts in the map.
 */
public final class BREBuilding {
    final BuildingDef buildingDef = new BuildingDef(true);
    final ArrayList<BRERoom> rooms = new ArrayList<>();

    public BRERoom createRoom(int level) {
        var room = new BRERoom(this);
        room.roomDef.level = level;
        rooms.add(room);
        buildingDef.getRooms().add(room.roomDef);
        return room;
    }

    public void removeRoom(BRERoom room) {
        buildingDef.getRooms().remove(room.roomDef);
        rooms.remove(room);
    }

    public BREBuilding copyFrom(BuildingDef def) {
        for (RoomDef room : def.rooms) createRoom(room.level).copyFrom(room);
        for (RoomDef room : def.emptyoutside) createRoom(room.level).copyFrom(room);
        return this;
    }

    public BuildingDef def() { return buildingDef; }
}
