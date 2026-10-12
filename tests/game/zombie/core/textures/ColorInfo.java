package zombie.core.textures;

/** Synthetic: the light of a square, as the lighting hands it. */
public class ColorInfo {
    public float r, g, b, a = 1.0f;
    public ColorInfo() { }
    public ColorInfo(float r, float g, float b) { this.r = r; this.g = g; this.b = b; }
    public ColorInfo setABGR(int abgr) {
        r = (abgr & 0xFF) / 255f; g = (abgr >> 8 & 0xFF) / 255f; b = (abgr >> 16 & 0xFF) / 255f; a = (abgr >>> 24) / 255f;
        return this;
    }
    public ColorInfo set(float r, float g, float b, float a) { this.r = r; this.g = g; this.b = b; this.a = a; return this; }
}
