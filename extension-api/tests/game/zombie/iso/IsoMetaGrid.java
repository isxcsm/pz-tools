package zombie.iso;

import java.util.ArrayList;
import java.util.List;
import zombie.buildingRooms.RemovedBuilding;

/** Synthetic: the map's rooms, which the game keeps for loaded and unloaded squares alike. */
public final class IsoMetaGrid {
    public final List<RoomDef> rooms = new ArrayList<>();
    public final ArrayList<BuildingDef> buildings = new ArrayList<>();
    private final ArrayList<RemovedBuilding> removedBuildings = new ArrayList<>();
    public RoomDef getRoomAt(int x, int y, int z) {
        for (RoomDef room : rooms)
            if (room.level == z) for (RoomDef.RoomRect rect : room.rects)
                if (x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h) return room;
        return null;
    }
    public RoomDef getRoomDefByID(long id) {
        for (RoomDef room : rooms) if (room.id == id) return room;
        return null;
    }
    public BuildingDef getBuildingAt(int x, int y, int z) {
        RoomDef room = getRoomAt(x, y, z);
        return room == null ? null : room.building;
    }
    public ArrayList<RemovedBuilding> getRemovedBuildings() { return removedBuildings; }
}
