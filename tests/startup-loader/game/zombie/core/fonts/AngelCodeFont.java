package zombie.core.fonts;

/**
 * Synthetic: a font's characters, by character code, as the game's (a code beyond the array, or a null entry, is a character the
 * font does not have), with its line height and the width of a character.
 */
public final class AngelCodeFont {
    public static final class CharDef { }

    public CharDef[] chars;
    public final int lineHeight, advance;
    public final boolean sdf;

    /** A font with every character up to {@code last}. */
    public AngelCodeFont(int last, int lineHeight, int advance, boolean sdf) {
        chars = new CharDef[last + 1];
        for (int code = 32; code <= last; code++) chars[code] = new CharDef();
        this.lineHeight = lineHeight;
        this.advance = advance;
        this.sdf = sdf;
    }

    public int getLineHeight() { return lineHeight; }

    /** Draws as the game's does at a zoom; recorded as TextManager.DrawString is, with this font in the place of the UIFont. */
    public void drawString(float x, float y, float scale, String text, float r, float g, float b, float a) {
        if (zombie.ui.TextManager.fail) throw new IllegalStateException("the drawing failed");
        zombie.ui.TextManager.drawn++;
        if (zombie.ui.TextManager.record) zombie.ui.TextManager.log("text", this, (double)x, (double)y, (double)scale, text, (double)r, (double)g, (double)b, (double)a);
    }
    public int getWidth(String text) { return text.length() * advance; }
    public boolean isSdf() { return sdf; }
}
