package zombie.iso;

/** Synthetic: a movement the animation gives, changed and returned as the game's is. */
public class Vector2 {
    public float x, y;
    public Vector2() { }
    public Vector2(float x, float y) { this.x = x; this.y = y; }
    public Vector2 set(float x, float y) { this.x = x; this.y = y; return this; }
    public void scale(float factor) { x *= factor; y *= factor; }
}
