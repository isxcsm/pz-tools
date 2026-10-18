package zombie.iso.areas;

import java.awt.Rectangle;
import zombie.iso.RoomDef;

/** Synthetic: a room, with the bounds of its rectangles. */
public class IsoRoom {
    public final Rectangle bounds;
    /** As the game's: the room's definition and building, when a test gives them. */
    public RoomDef def;
    public IsoBuilding building;
    public IsoRoom(int x, int y, int w, int h) { bounds = new Rectangle(x, y, w, h); }
    public Rectangle getRectsBounds() { return bounds; }
    public RoomDef getRoomDef() { return def; }
    public IsoBuilding getBuilding() { return building; }
}
