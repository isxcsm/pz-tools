package zombie.iso.fboRenderChunk;

import zombie.iso.IsoObject;

/** Synthetic: the per-frame outline pass; the game draws an outlined object's sprite silhouette here. */
public final class FBORenderObjectOutline {
    public static final FBORenderObjectOutline instance = new FBORenderObjectOutline();
    public int sprites;
    public void render(int player, IsoObject object) { renderObject(player, object); }
    private void renderObject(int player, IsoObject object) { sprites++; }
}
