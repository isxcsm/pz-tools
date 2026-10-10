package zombie.core.fonts;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import zombie.ZomboidFileSystem;

/**
 * Synthetic: a font's characters, by character code, as the game's (a code beyond the array, or a null entry, is a character the
 * font does not have), with its line height and the width of a character. A font read from a file, as the game reads one, takes
 * these from its {@code common lineHeight=} line and a {@code pztools-test last= advance=} line, and is still loading its
 * pictures when {@link #loadingNew} is set as it is made.
 */
public final class AngelCodeFont {
    public static final class CharDef { }

    /** How many fonts were read from files; the last one. */
    public static int made;
    public static AngelCodeFont lastMade;
    /** Set to have a font read from a file wait for its pictures until the test clears its {@link #loading}. */
    public static boolean loadingNew;

    public CharDef[] chars;
    public int lineHeight, advance;
    public boolean sdf, loading, destroyed;
    /** The file it was read from (the game's is private), or null. */
    private File fntFile;
    public final String path;

    /** A font with every character up to {@code last}. */
    public AngelCodeFont(int last, int lineHeight, int advance, boolean sdf) {
        chars = chars(last);
        this.lineHeight = lineHeight;
        this.advance = advance;
        this.sdf = sdf;
        path = null;
    }

    /** A font read as the game reads one: its path through the game's file system. */
    public AngelCodeFont(String fnt, String img) throws FileNotFoundException {
        path = ZomboidFileSystem.instance.getString(fnt);
        fntFile = new File(path);
        if (!fntFile.isFile()) throw new FileNotFoundException(path);
        int last = 0;
        try {
            for (String line : Files.readAllLines(fntFile.toPath(), StandardCharsets.ISO_8859_1))
                for (String field : line.split(" +")) {
                    if (field.startsWith("lineHeight=")) lineHeight = Integer.parseInt(field.substring(11));
                    if (field.startsWith("last=")) last = Integer.parseInt(field.substring(5));
                    if (field.startsWith("advance=")) advance = Integer.parseInt(field.substring(8));
                }
        } catch (IOException failure) { throw new FileNotFoundException(failure.toString()); }
        chars = chars(last);
        loading = loadingNew;
        made++;
        lastMade = this;
    }

    private static CharDef[] chars(int last) {
        var chars = new CharDef[last + 1];
        for (int code = 32; code <= last; code++) chars[code] = new CharDef();
        return chars;
    }

    public int getLineHeight() { return lineHeight; }

    /** Draws as the game's does at a zoom; recorded as TextManager.DrawString is, with this font in the place of the UIFont. */
    public void drawString(float x, float y, float scale, String text, float r, float g, float b, float a) {
        if (zombie.ui.TextManager.fail) throw new IllegalStateException("the drawing failed");
        zombie.ui.TextManager.drawn++;
        if (zombie.ui.TextManager.record) zombie.ui.TextManager.log("text", this, (double)x, (double)y, (double)scale, text, (double)r, (double)g, (double)b, (double)a);
    }

    /** Draws at the font's own size, as the game's DrawText does; recorded with a zoom of 0 (the game's own word for none). */
    public void drawString(float x, float y, String text, float r, float g, float b, float a) { drawString(x, y, 0f, text, r, g, b, a); }

    public int getWidth(String text) { return text.length() * advance; }
    public boolean isSdf() { return sdf; }
    public void setSdf(boolean sdf) { this.sdf = sdf; }
    public boolean isLoading() { return loading; }

    /** Lets the characters go, as the game's does when it makes its fonts again. */
    public void destroy() {
        destroyed = true;
        java.util.Arrays.fill(chars, null);
    }
}
