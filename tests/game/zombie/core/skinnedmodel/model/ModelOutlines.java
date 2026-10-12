package zombie.core.skinnedmodel.model;

import zombie.core.textures.ColorInfo;
import zombie.core.textures.TextureFBO;

/** Synthetic: the outline buffers; each outline begun kept as its colour and whether it is behind. */
public final class ModelOutlines {
    public static final ModelOutlines instance = new ModelOutlines();
    public TextureFBO fboA;
    public int begun;
    public boolean behind;
    public boolean beginRenderOutline(ColorInfo colour, boolean behind, boolean xray) {
        this.behind = behind;
        return begun++ == 0;
    }
}
