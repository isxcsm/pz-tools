package zombie.iso.sprite;

/** Synthetic: one animation as an object holds it (an attached one), with its frame and speed. */
public final class IsoSpriteInstance {
    public IsoSprite parentSprite;
    public float frame;
    public float animFrameIncrease = 1f;
    /** How many times the game called {@link #update()}. */
    public int updates;
    public IsoSpriteInstance(IsoSprite parentSprite) { this.parentSprite = parentSprite; }
    public IsoSprite getParentSprite() { return parentSprite; }
    public void setFrameSpeedPerFrame(float speed) { animFrameIncrease = speed; }
    /** Does nothing in the game; counted here. */
    public void update() { updates++; }
}
