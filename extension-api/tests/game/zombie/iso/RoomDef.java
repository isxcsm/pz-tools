package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class RoomDef {
    public long id;
    public String name;
    public int level;
    public BuildingDef building;
    public boolean explored, doneSpawn, lightsActive, roofFixed;
    /** As the game's: the room's number in its cell's map_meta.bin (made from its first rectangle). */
    public long metaId;
    public final ArrayList<RoomRect> rects = new ArrayList<>();
    public final ArrayList<MetaObject> objects = new ArrayList<>();
    public RoomDef(long id, String name, int level, BuildingDef building) {
        this.id = id; this.name = name; this.level = level; this.building = building;
        building.rooms.add(this);
    }
    /** As the game's: a room of no building yet. */
    public RoomDef(long id, String name) { this.id = id; this.name = name; }
    public BuildingDef getBuilding() { return building; }
    public String getName() { return name; }
    public int getZ() { return level; }
    public ArrayList<RoomRect> getRects() { return rects; }
    public long getID() { return id; }
    public boolean isRoofFixed() { return roofFixed; }
    public boolean isEmptyOutside() { return "emptyoutside".equals(name); }
    public void CalculateBounds() { }

    /** As the game's: the flags, the name, the level and the rectangles (not the objects). */
    public void copyFrom(RoomDef other) {
        explored = other.explored; doneSpawn = other.doneSpawn; lightsActive = other.lightsActive;
        name = other.name; level = other.level;
        for (RoomRect rect : other.rects) rects.add(new RoomRect(rect.x, rect.y, rect.w, rect.h));
    }

    public static final class RoomRect {
        public int x, y, w, h;
        public RoomRect(int x, int y, int w, int h) { this.x = x; this.y = y; this.w = w; this.h = h; }
        public int getX() { return x; }
        public int getY() { return y; }
        public int getW() { return w; }
        public int getH() { return h; }
    }
}
