package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class RoomDef {
    public long id;
    public String name;
    public int level;
    public BuildingDef building;
    public final ArrayList<RoomRect> rects = new ArrayList<>();
    public RoomDef(long id, String name, int level, BuildingDef building) {
        this.id = id; this.name = name; this.level = level; this.building = building;
        building.rooms.add(this);
    }
    public BuildingDef getBuilding() { return building; }
    public String getName() { return name; }
    public int getZ() { return level; }
    public ArrayList<RoomRect> getRects() { return rects; }
    public long getID() { return id; }

    public static final class RoomRect {
        public int x, y, w, h;
        public RoomRect(int x, int y, int w, int h) { this.x = x; this.y = y; this.w = w; this.h = h; }
        public int getX() { return x; }
        public int getY() { return y; }
        public int getW() { return w; }
        public int getH() { return h; }
    }
}
