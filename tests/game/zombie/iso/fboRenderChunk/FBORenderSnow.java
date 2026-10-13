package zombie.iso.fboRenderChunk;

import zombie.iso.IsoChunk;

/** Synthetic: the snow drawn on a chunk level's floors, after them; here only counted. */
public final class FBORenderSnow {
    private static final FBORenderSnow INSTANCE = new FBORenderSnow();
    public int levels;

    public static FBORenderSnow getInstance() { return INSTANCE; }

    public void RenderSnow(IsoChunk chunk, int level) { levels++; }
}
