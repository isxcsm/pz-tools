package zombie.core.textures;

import zombie.interfaces.ITexture;
import zombie.ui.TextManager;

/** Synthetic: a frame buffer over a texture. Its making, drawing into and letting go are recorded with the text drawn. */
public final class TextureFBO {
    /** Whether the game can make frame buffers; how many were made and let go; the one drawn into. */
    public static boolean supported = true;
    public static int made, destroyed;
    public static TextureFBO drawing, last;
    private final ITexture texture;
    public boolean isDestroyed;

    public TextureFBO(ITexture texture) {
        this.texture = texture;
        last = this;
        made++;
        if (TextManager.record) TextManager.log("fbo", texture);
    }

    public static boolean checkFBOSupport() { return supported; }

    public ITexture getTexture() { return texture; }

    public void startDrawing(boolean clear, boolean transparent) {
        drawing = this;
        if (TextManager.record) TextManager.log("fbo-start", clear, transparent);
    }

    public void endDrawing() {
        drawing = null;
        if (TextManager.record) TextManager.log("fbo-end");
    }

    /** Lets the frame buffer and its texture go. */
    public void destroy() {
        destroyed++;
        isDestroyed = true;
        ((Texture)texture).destroy();
    }
}
