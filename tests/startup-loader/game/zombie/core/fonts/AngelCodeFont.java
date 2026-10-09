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
    public int getWidth(String text) { return text.length() * advance; }
    public boolean isSdf() { return sdf; }
}
