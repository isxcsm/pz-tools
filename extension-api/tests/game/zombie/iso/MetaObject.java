package zombie.iso;

/** Synthetic: an object of the map in a room (where its zombies stand). */
public final class MetaObject {
    int type;
    int x;
    int y;
    RoomDef def;
    public MetaObject(int x, int y, RoomDef def) { this.x = x; this.y = y; this.def = def; def.objects.add(this); }
    public RoomDef def() { return def; }
}
