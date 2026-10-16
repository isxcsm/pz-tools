package zombie.iso;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.function.Predicate;
import java.util.function.UnaryOperator;
import zombie.buildingRooms.RemovedBuilding;
import zombie.debug.DebugType;

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

    // ---- the map's data on rooms and buildings (map_meta.bin), as the game saves and reads it ----

    /** The version the file is written in; the building's alarm decay is in it from 201 on. */
    private static final int VERSION = 249;
    /** The cells the map has, from cell minX, minY to maxX, maxY (none: maxX is below minX). */
    public int minX, minY, maxX = -1, maxY = -1;
    private IsoMetaCell[][] cells = new IsoMetaCell[0][0];

    /** Test: the map has these cells, the first at cell minX, minY (cells[x][y], as the game keeps them). */
    public void setCells(int minX, int minY, IsoMetaCell[][] cells) {
        this.minX = minX;
        this.minY = minY;
        this.cells = cells;
        this.maxX = minX + cells.length - 1;
        this.maxY = minY + (cells.length == 0 ? 0 : cells[0].length) - 1;
    }

    public int gridX() { return maxX - minX + 1; }

    public int gridY() { return maxY - minY + 1; }

    /** The cell at the cell's own coordinates, or null where the map has none. */
    public IsoMetaCell getCellData(int x, int y) {
        if (x - minX < 0 || y - minY < 0 || x - minX >= gridX() || y - minY >= gridY()) return null;
        return cells[x - minX][y - minY];
    }

    /**
     * The world's save of the map's data: part 0 is the map's rooms and buildings (map_meta.bin), shaped as the game's is: for each
     * cell, the count of its rooms (those players built left out) and an entry for each (its number and flags), then the count of its
     * buildings and an entry for each. The other part is the lists that follow in the game (safe houses and the rest), which the
     * synthetic game has none of.
     */
    public void savePart(ByteBuffer buffer, int part, boolean network) {
        if (part == 0) {
            buffer.put((byte)'M');
            buffer.put((byte)'E');
            buffer.put((byte)'T');
            buffer.put((byte)'A');
            buffer.putInt(VERSION);
            buffer.putInt(minX);
            buffer.putInt(minY);
            buffer.putInt(maxX);
            buffer.putInt(maxY);
            for (int x = 0; x < gridX(); x++) {
                for (int y = 0; y < gridY(); y++) {
                    IsoMetaCell cell = cells[x][y];
                    int rooms = 0;
                    if (cell != null && cell.info != null) rooms = cell.getRoomCount(true);
                    buffer.putInt(rooms);
                    if (cell != null && cell.info != null) {
                        for (RoomDef room : cell.roomList) {
                            if (room.userDefined) continue;
                            buffer.putLong(room.metaId);
                            short flags = 0;
                            if (room.explored) flags = (short)(flags | 1);
                            if (room.lightsActive) flags = (short)(flags | 2);
                            if (room.doneSpawn) flags = (short)(flags | 4);
                            if (room.isRoofFixed()) flags = (short)(flags | 8);
                            buffer.putShort(flags);
                        }
                    }
                    if (cell != null && cell.info != null) buffer.putInt(cell.getBuildingCount(true));
                    else buffer.putInt(0);
                    if (cell != null && cell.info != null) {
                        for (BuildingDef building : cell.buildings) {
                            if (building.isUserDefined()) continue;
                            buffer.putLong(building.metaId);
                            buffer.put((byte)(building.alarmed ? 1 : 0));
                            buffer.putInt(building.getKeyId());
                            buffer.put((byte)(building.seen ? 1 : 0));
                            buffer.put((byte)(building.isHasBeenVisited() ? 1 : 0));
                            buffer.putInt(building.lootRespawnHour);
                            buffer.putInt(building.alarmDecay);
                        }
                    }
                }
            }
            return;
        }
        buffer.putInt(0);
    }

    /**
     * Reads what {@link #savePart} writes for part 0. An entry the cell has no room (or building) for is the game's complaint, said
     * on the General channel with the words the API looks for.
     */
    public void load(ByteBuffer buffer) {
        buffer.mark();
        buffer.get();
        buffer.get();
        buffer.get();
        buffer.get();
        int version = buffer.getInt();
        int fromX = buffer.getInt();
        int fromY = buffer.getInt();
        int toX = buffer.getInt();
        int toY = buffer.getInt();
        for (int x = fromX; x <= toX; x++) {
            for (int y = fromY; y <= toY; y++) {
                IsoMetaCell cell = getCellData(x, y);
                int rooms = buffer.getInt();
                for (int each = 0; each < rooms; each++) {
                    long id = buffer.getLong();
                    short flags = buffer.getShort();
                    boolean explored = (flags & 1) != 0;
                    boolean lights = (flags & 2) != 0;
                    boolean spawned = (flags & 4) != 0;
                    boolean roof = (flags & 8) != 0;
                    if (cell != null && cell.info != null) {
                        RoomDef room = cell.roomByMetaId.get(id);
                        if (room != null) {
                            room.setExplored(explored);
                            room.lightsActive = lights;
                            room.doneSpawn = spawned;
                            room.setRoofFixed(roof);
                        } else {
                            DebugType.General.error("invalid room metaID #" + id + " in cell " + x + "," + y + " while reading map_meta.bin");
                        }
                    }
                }
                int buildings = buffer.getInt();
                for (int each = 0; each < buildings; each++) {
                    long id = buffer.getLong();
                    boolean alarmed = buffer.get() != 0;
                    int key = buffer.getInt();
                    boolean seen = buffer.get() != 0;
                    boolean visited = buffer.get() != 0;
                    int respawn = buffer.getInt();
                    int decay = version >= 201 ? buffer.getInt() : 0;
                    if (cell != null && cell.info != null) {
                        BuildingDef building = cell.buildingByMetaId.get(id);
                        if (building != null) {
                            building.alarmed = alarmed;
                            building.setKeyId(key);
                            building.seen = seen;
                            building.hasBeenVisited = visited;
                            building.lootRespawnHour = respawn;
                            building.alarmDecay = decay;
                        } else {
                            DebugType.General.error("invalid building metaID #" + id + " in cell " + x + "," + y + " while reading map_meta.bin");
                        }
                    }
                }
            }
        }
    }
}
