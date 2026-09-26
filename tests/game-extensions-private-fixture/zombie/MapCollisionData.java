package zombie;
public final class MapCollisionData {
    public static final MapCollisionData instance = new MapCollisionData();
    public int calls;
    public void save() { calls++; }
}
