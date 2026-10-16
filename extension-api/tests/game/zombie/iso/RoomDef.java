package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class RoomDef {
    public long id;
    public String name;
    public int level;
    public BuildingDef building;
    public boolean explored, doneSpawn, lightsActive;
    /** Counts every change to any room's rectangles (and levels set by copyFrom), for the index IsoMetaGrid keeps by chunk. */
    static int shapes;
    private static final class Rects extends ArrayList<RoomRect> {
        @Override public boolean add(RoomRect rect) { shapes++; return super.add(rect); }
        @Override public void add(int index, RoomRect rect) { shapes++; super.add(index, rect); }
        @Override public boolean addAll(java.util.Collection<? extends RoomRect> all) { shapes++; return super.addAll(all); }
        @Override public RoomRect set(int index, RoomRect rect) { shapes++; return super.set(index, rect); }
        @Override public RoomRect remove(int index) { shapes++; return super.remove(index); }
        @Override public boolean remove(Object rect) { shapes++; return super.remove(rect); }
        @Override public boolean removeAll(java.util.Collection<?> all) { shapes++; return super.removeAll(all); }
        @Override public boolean removeIf(java.util.function.Predicate<? super RoomRect> filter) { shapes++; return super.removeIf(filter); }
        @Override public void clear() { shapes++; super.clear(); }
    }
    public final ArrayList<RoomRect> rects = new Rects();
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
    public boolean isEmptyOutside() { return "emptyoutside".equals(name); }
    public void CalculateBounds() { }

    /** As the game's: the flags, the name, the level and the rectangles (not the objects). */
    public void copyFrom(RoomDef other) {
        explored = other.explored; doneSpawn = other.doneSpawn; lightsActive = other.lightsActive;
        name = other.name; level = other.level;
        shapes++;
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
