package zombie.core.textures;

/** Synthetic: one draw of the render queue. */
public final class TextureDraw {
    /** Synthetic: what a queued draw of its own runs on the render thread. */
    public abstract static class GenericDrawer {
        public abstract void render();

        public void postRender() { }
    }
}
