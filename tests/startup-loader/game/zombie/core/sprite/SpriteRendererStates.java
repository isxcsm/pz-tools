package zombie.core.sprite;

/** Synthetic: the sprite renderer's states; one is filled. */
public final class SpriteRendererStates {
    private final GenericSpriteRenderState populating = new GenericSpriteRenderState();

    public GenericSpriteRenderState getPopulatingActiveState() { return populating; }
}
