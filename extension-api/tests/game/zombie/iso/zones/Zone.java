package zombie.iso.zones;

/** Synthetic: a zone of the map, a box of one level with a type. */
public class Zone {
    public String name, type;
    public int x, y, z, w, h;
    /** Test: how many times a zone's box was read (an answer kept reads none). */
    public static int reads;
    public Zone(String name, String type, int x, int y, int z, int w, int h) {
        this.name = name; this.type = type; this.x = x; this.y = y; this.z = z; this.w = w; this.h = h;
    }
    public String getType() { return type; }
    public String getName() { return name; }
    public boolean contains(int px, int py, int pz) { return pz == z && px >= x && px < x + w && py >= y && py < y + h; }
    public int getX() { reads++; return x; }
    public int getY() { return y; }
    public int getWidth() { return w; }
    public int getHeight() { return h; }
    /** Synthetic: a polyline's points (x0, y0, x1, y1, ...), its box the points' (as the game keeps it); null for a box. */
    public java.util.List<Integer> line;
    public boolean isPolyline() { return line != null; }
    public java.util.List<Integer> getPointsToLua() { return line; }
}
