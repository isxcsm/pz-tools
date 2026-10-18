package zombie.iso.zones;

/** Synthetic: a zone of the map, a box of one level with a type. */
public final class Zone {
    public String type;
    public int x, y, z, w, h;
    public Zone(String type, int x, int y, int z, int w, int h) { this.type = type; this.x = x; this.y = y; this.z = z; this.w = w; this.h = h; }
    public String getType() { return type; }
    public boolean contains(int px, int py, int pz) { return pz == z && px >= x && px < x + w && py >= y && py < y + h; }
}
