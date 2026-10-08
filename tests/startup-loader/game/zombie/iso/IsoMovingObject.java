package zombie.iso;

/** Synthetic: what moves (a character); the trees ask it how they slow it, and the vision looks at where it stands. */
public class IsoMovingObject extends IsoObject {
    public float x, y, z;
    public IsoMovingObject() { super(null); }
    public float getX() { return x; }
    public float getY() { return y; }
    public float getZ() { return z; }
    public IsoGridSquare getCurrentSquare() { return square; }
}
