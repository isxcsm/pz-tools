package zombie.iso.areas;

import java.awt.Rectangle;

/** Synthetic: a room, with the bounds of its rectangles. */
public class IsoRoom {
    public final Rectangle bounds;
    /** The room's definition in the map, if a test gives one. */
    public zombie.iso.RoomDef def;
    public zombie.iso.RoomDef getRoomDef() { return def; }
    public IsoRoom(int x, int y, int w, int h) { bounds = new Rectangle(x, y, w, h); }
    public Rectangle getRectsBounds() { return bounds; }
}
