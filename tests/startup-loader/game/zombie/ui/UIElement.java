package zombie.ui;

import java.util.ArrayList;
import java.util.List;
import zombie.core.textures.Texture;

/**
 * Synthetic: a window of the game's interface. Where it is (its place and its parent's), whether it is shown and how far it is scrolled
 * are what the shapes drawn from it are placed by; the quads drawn with {@code DrawTexture} are recorded.
 */
public class UIElement {
    public double x, y;
    public UIElement parent;
    public boolean visible = true;
    public Double xScroll = 0.0, yScroll = 0.0;
    /** How often the place was asked for: a batch asks once. */
    public int placeAsks;
    /** The quads drawn: the texture, the eight coordinates and the four colour parts. */
    public final List<Object[]> quads = new ArrayList<>();

    public Boolean isVisible() { return visible; }
    public Double getAbsoluteX() { placeAsks++; return x + (parent == null ? 0 : parent.getAbsoluteX()); }
    public Double getAbsoluteY() { placeAsks++; return y + (parent == null ? 0 : parent.getAbsoluteY()); }
    public Double getXScroll() { return xScroll; }
    public Double getYScroll() { return yScroll; }

    public void DrawTexture(Texture texture, double x1, double y1, double x2, double y2, double x3, double y3, double x4, double y4,
            double r, double g, double b, double a) {
        quads.add(new Object[] { texture, x1, y1, x2, y2, x3, y3, x4, y4, r, g, b, a });
    }
}
