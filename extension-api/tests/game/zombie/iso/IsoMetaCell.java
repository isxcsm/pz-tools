package zombie.iso;

import gnu.trove.map.hash.TLongObjectHashMap;
import java.util.ArrayList;

/**
 * Synthetic: a cell of the map's data on rooms and buildings (map_meta.bin keeps each room's flags under its number in the cell, and
 * each building's). As the game's, a cell with no header has none of it, and the counts of the world's save leave out what players built.
 */
public final class IsoMetaCell {
    private final int x, y;
    public LotHeader info = new LotHeader();
    public final ArrayList<RoomDef> roomList = new ArrayList<>();
    public final TLongObjectHashMap<RoomDef> roomByMetaId = new TLongObjectHashMap<>();
    public final ArrayList<BuildingDef> buildings = new ArrayList<>();
    public final TLongObjectHashMap<BuildingDef> buildingByMetaId = new TLongObjectHashMap<>();

    public IsoMetaCell(int x, int y) { this.x = x; this.y = y; }

    public int getX() { return x; }

    public int getY() { return y; }

    public int getRoomCount(boolean map) {
        if (!map) return roomList.size();
        int count = 0;
        for (RoomDef room : roomList) if (!room.userDefined) count++;
        return count;
    }

    public int getBuildingCount(boolean map) {
        if (!map) return buildings.size();
        int count = 0;
        for (BuildingDef building : buildings) if (!building.isUserDefined()) count++;
        return count;
    }
}
