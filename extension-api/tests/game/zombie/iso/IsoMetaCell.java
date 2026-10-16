package zombie.iso;

import gnu.trove.map.hash.TLongObjectHashMap;
import java.util.ArrayList;

/** Synthetic: a cell of the map's data on rooms (map_meta.bin keeps each room's flags under its number in the cell). */
public final class IsoMetaCell {
    private final int x, y;
    public final ArrayList<RoomDef> roomList = new ArrayList<>();
    public final TLongObjectHashMap<RoomDef> roomByMetaId = new TLongObjectHashMap<>();

    public IsoMetaCell(int x, int y) { this.x = x; this.y = y; }

    public int getX() { return x; }

    public int getY() { return y; }

    public int getRoomCount(boolean counted) { return roomList.size(); }

    public int getBuildingCount(boolean counted) { return 0; }
}
