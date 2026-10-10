package zombie.core;

import java.util.ArrayList;
import java.util.List;
import zombie.core.Styles.AbstractStyle;
import zombie.core.sprite.SpriteRendererStates;
import zombie.core.textures.Texture;
import zombie.core.textures.TextureDraw;
import zombie.ui.TextManager;

/**
 * Synthetic: the game's sprite renderer. A quad with its texture coordinates, a style set and a drawer queued are recorded with the
 * text drawn ({@code TextManager.calls}); the drawers wait for {@link #flush}, as the render thread runs them after the frame.
 */
public final class SpriteRenderer {
    public static final SpriteRenderer instance = new SpriteRenderer();
    public final SpriteRendererStates states = new SpriteRendererStates();
    /** The drawers queued and not yet run; the quads drawn, recorded or not. */
    public static final List<TextureDraw.GenericDrawer> queued = new ArrayList<>();
    public static int quads;

    /** A quad: its four corners (from the top left, clockwise), their texture coordinates, its colour. */
    public void render(Texture texture, double x0, double y0, double x1, double y1, double x2, double y2, double x3, double y3, double u0, double v0,
            double u1, double v1, double u2, double v2, double u3, double v3, float r, float g, float b, float a) {
        if (TextManager.fail) throw new IllegalStateException("the drawing failed");
        quads++;
        if (TextManager.record) TextManager.log("quad", texture, x0, y0, x1, y1, x2, y2, x3, y3, u0, v0, u1, v1, u2, v2, u3, v3, r, g, b, a);
    }

    /** The rectangles drawn from a window by whole pixels: the texture, x, y, w, h and the colour. */
    public static final List<Object[]> rects = new ArrayList<>();

    public void renderi(Texture texture, int x, int y, int w, int h, float r, float g, float b, float a, java.util.function.Consumer<TextureDraw> consumer) {
        rects.add(new Object[] { texture, x, y, w, h, r, g, b, a });
    }

    public TextureDraw drawGeneric(TextureDraw.GenericDrawer drawer) {
        if (TextManager.record) TextManager.log("generic", drawer);
        queued.add(drawer);
        return null;
    }

    public void setDefaultStyle(AbstractStyle style) {
        states.getPopulatingActiveState().defaultStyle = style;
        if (TextManager.record) TextManager.log("style", style);
    }

    /** Runs the drawers queued, in order, as the render thread does. */
    public static void flush() {
        var drawers = new ArrayList<>(queued);
        queued.clear();
        for (TextureDraw.GenericDrawer drawer : drawers) drawer.render();
    }
}
