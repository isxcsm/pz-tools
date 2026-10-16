package zombie.iso;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.function.Predicate;
import java.util.function.UnaryOperator;
import zombie.buildingRooms.RemovedBuilding;

/**
 * Synthetic: the map's rooms, which the game keeps for loaded and unloaded squares alike. Like the game's
 * (IsoMetaChunk.getRoomAt), a question looks only at the rooms of one chunk of the map: the rooms are kept by the chunks
 * their rectangles touch, made again when the list of rooms or a room's rectangles change. A question allocates nothing,
 * as the game's does not.
 */
public final class IsoMetaGrid {
    /** The squares on a side of the chunks the rooms are kept in. */
    private static final int CHUNK = 8;

    /** A list of rooms that counts its changes, so that the index by chunk is made again after one. */
    private static final class Rooms extends ArrayList<RoomDef> {
        int version;
        @Override public boolean add(RoomDef room) { version++; return super.add(room); }
        @Override public void add(int index, RoomDef room) { version++; super.add(index, room); }
        @Override public boolean addAll(Collection<? extends RoomDef> all) { version++; return super.addAll(all); }
        @Override public boolean addAll(int index, Collection<? extends RoomDef> all) { version++; return super.addAll(index, all); }
        @Override public RoomDef set(int index, RoomDef room) { version++; return super.set(index, room); }
        @Override public RoomDef remove(int index) { version++; return super.remove(index); }
        @Override public boolean remove(Object room) { version++; return super.remove(room); }
        @Override public boolean removeAll(Collection<?> all) { version++; return super.removeAll(all); }
        @Override public boolean retainAll(Collection<?> all) { version++; return super.retainAll(all); }
        @Override public boolean removeIf(Predicate<? super RoomDef> filter) { version++; return super.removeIf(filter); }
        @Override public void replaceAll(UnaryOperator<RoomDef> operator) { version++; super.replaceAll(operator); }
        @Override public void clear() { version++; super.clear(); }
        @Override public void sort(java.util.Comparator<? super RoomDef> order) { version++; super.sort(order); }
    }

    private final Rooms roomList = new Rooms();
    public final List<RoomDef> rooms = roomList;
    public final ArrayList<BuildingDef> buildings = new ArrayList<>();
    private final ArrayList<RemovedBuilding> removedBuildings = new ArrayList<>();
    // The rooms by the chunk of the map their rectangles touch, in the order of the list; and the version they were made at.
    private LongTable<ArrayList<RoomDef>> byChunk = new LongTable<>();
    private LongTable<RoomDef> byId = new LongTable<>();
    private int indexedRooms = -1, indexedShapes = -1;

    private void index() {
        if (indexedRooms == roomList.version && indexedShapes == RoomDef.shapes) return;
        var chunks = new LongTable<ArrayList<RoomDef>>();
        var ids = new LongTable<RoomDef>();
        for (RoomDef room : roomList) {
            if (ids.get(room.id) == null) ids.put(room.id, room);
            var seen = new HashSet<Long>();
            for (RoomDef.RoomRect rect : room.rects) {
                if (rect.w <= 0 || rect.h <= 0) continue;
                for (int cy = Math.floorDiv(rect.y, CHUNK); cy <= Math.floorDiv(rect.y + rect.h - 1, CHUNK); cy++)
                    for (int cx = Math.floorDiv(rect.x, CHUNK); cx <= Math.floorDiv(rect.x + rect.w - 1, CHUNK); cx++) {
                        long key = chunkKey(cx, cy);
                        if (!seen.add(key)) continue;
                        ArrayList<RoomDef> list = chunks.get(key);
                        if (list == null) chunks.put(key, list = new ArrayList<>());
                        list.add(room);
                    }
            }
        }
        byChunk = chunks;
        byId = ids;
        indexedRooms = roomList.version;
        indexedShapes = RoomDef.shapes;
    }

    private static long chunkKey(int cx, int cy) { return (long)cx << 32 | cy & 0xFFFFFFFFL; }

    public RoomDef getRoomAt(int x, int y, int z) {
        index();
        ArrayList<RoomDef> near = byChunk.get(chunkKey(Math.floorDiv(x, CHUNK), Math.floorDiv(y, CHUNK)));
        if (near == null) return null;
        for (int at = 0; at < near.size(); at++) {
            RoomDef room = near.get(at);
            if (room.level != z) continue;
            for (int each = 0; each < room.rects.size(); each++) {
                RoomDef.RoomRect rect = room.rects.get(each);
                if (x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h) return room;
            }
        }
        return null;
    }
    public RoomDef getRoomDefByID(long id) {
        index();
        RoomDef found = byId.get(id);
        if (found != null && found.id == id) return found;
        // Not (or no longer) the index's: a room whose number was changed in place.
        for (RoomDef room : roomList) if (room.id == id) return room;
        return null;
    }
    public BuildingDef getBuildingAt(int x, int y, int z) {
        RoomDef room = getRoomAt(x, y, z);
        return room == null ? null : room.building;
    }
    public ArrayList<RemovedBuilding> getRemovedBuildings() { return removedBuildings; }
}
