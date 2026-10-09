package zombie.ui;

import java.util.ArrayList;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import zombie.core.fonts.AngelCodeFont;
import zombie.core.opengl.SDFShader;

/**
 * Synthetic: the game's text drawing. Its fonts are bitmap fonts with the Latin characters and Hangul (Small, Medium, Large, Title:
 * a language's), or Latin alone (Massive, and the distance-field fonts). What it draws is recorded in {@link #calls} while
 * {@link #record} is set.
 */
public final class TextManager {
    public static final TextManager instance = new TextManager();
    /** The game's distance-field shader; null until the game made it. */
    public static SDFShader sdfShader = new SDFShader();
    /** What was drawn, in order, with the interface around it (UIManager.render) and the shader (IndieGL): one entry a call. */
    public static final List<Object[]> calls = new ArrayList<>();
    public static boolean record = true;
    /** Set to have the drawing fail, as a game that changed might. */
    public static boolean fail;
    /** How many strings were drawn, recorded or not. */
    public static int drawn;
    public final Map<UIFont, AngelCodeFont> fonts = new EnumMap<>(UIFont.class);

    private TextManager() { reset(); }

    /** The fonts as the game loads them (the font size option makes them again). */
    public void reset() {
        fonts.put(UIFont.Small, new AngelCodeFont(0xD7A3, 18, 8, false));
        fonts.put(UIFont.Medium, new AngelCodeFont(0xD7A3, 24, 11, false));
        fonts.put(UIFont.Large, new AngelCodeFont(0xD7A3, 33, 15, false));
        fonts.put(UIFont.Title, new AngelCodeFont(0xD7A3, 33, 15, false));
        fonts.put(UIFont.Massive, new AngelCodeFont(0x7E, 47, 22, false));
        fonts.put(UIFont.SdfRegular, new AngelCodeFont(0x4FF, 45, 18, true));
        fonts.put(UIFont.SdfBold, new AngelCodeFont(0x4FF, 45, 20, true));
        fonts.put(UIFont.SdfRobertoSans, new AngelCodeFont(0x4FF, 69, 28, true));
    }

    public static void log(Object... call) { calls.add(call); }

    public void DrawString(UIFont font, double x, double y, double zoom, String text, double r, double g, double b, double a) {
        if (fail) throw new IllegalStateException("the drawing failed");
        drawn++;
        if (record) log("text", font, x, y, zoom, text, r, g, b, a);
    }

    public int MeasureStringX(UIFont font, String text) { return getFontFromEnum(font).getWidth(text); }
    public int getFontHeight(UIFont font) { return getFontFromEnum(font).getLineHeight(); }
    public boolean isSdf(UIFont font) { return getFontFromEnum(font).isSdf(); }
    public AngelCodeFont getFontFromEnum(UIFont font) { return fonts.get(font); }
}
