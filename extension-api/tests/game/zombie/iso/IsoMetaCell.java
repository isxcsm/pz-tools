package zombie.iso;

import gnu.trove.map.hash.TLongObjectHashMap;
import java.util.ArrayList;

/**
 * Synthetic: a cell of the map's data on rooms and buildings (map_meta.bin keeps each room's flags under its number in the cell, and
 * each building's). As the game's, a cell with no header has none of it, and the counts of the world's save leave out what players built.
 * It also keeps the cell's chunks (32 by 32), made when first asked for with the intensity the header gives.
 */
public final class IsoMetaCell {
    private final int x, y;
    public LotHeader info = new LotHeader();
    public final ArrayList<RoomDef> roomList = new ArrayList<>();
    public final TLongObjectHashMap<RoomDef> roomByMetaId = new TLongObjectHashMap<>();
    public final ArrayList<BuildingDef> buildings = new ArrayList<>();
    public final TLongObjectHashMap<BuildingDef> buildingByMetaId = new TLongObjectHashMap<>();
    private final IsoMetaChunk[] chunkMap = new IsoMetaChunk[1024];
    /** Test: how many times a chunk was asked about (an answer kept asks none). */
    public static int reads;

    public IsoMetaCell(int x, int y) { this.x = x; this.y = y; }

    public int getX() { return x; }

    public int getY() { return y; }

    public boolean hasChunk(int x, int y) {
        reads++;
        return x >= 0 && y >= 0 && x < 32 && y < 32 && chunkMap[y * 32 + x] != null;
    }

    /** As the game's: made when first asked for, with the intensity the header gives (0 when it has none). */
    public IsoMetaChunk getChunk(int x, int y) {
        if (x < 0 || y < 0 || x >= 32 || y >= 32) return null;
        int at = y * 32 + x;
        if (chunkMap[at] == null) {
            chunkMap[at] = new IsoMetaChunk();
            chunkMap[at].setZombieIntensity((byte)Math.max(0, LotHeader.getZombieIntensityForChunk(info, x, y)));
        }
        return chunkMap[at];
    }

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
