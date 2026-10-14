package zombie.iso.areas;

import java.awt.Rectangle;

/** Synthetic: a room, with the bounds of its rectangles. */
public class IsoRoom {
    public final Rectangle bounds;
    public IsoRoom(int x, int y, int w, int h) { bounds = new Rectangle(x, y, w, h); }
    public Rectangle getRectsBounds() { return bounds; }
}
