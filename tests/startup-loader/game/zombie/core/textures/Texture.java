package zombie.core.textures;

import java.util.HashMap;
import java.util.Map;

/**
 * Synthetic: a picture. The files there are, by path, are what the test puts in {@link #FILES}; the game reads a file's size as
 * it loads it, which a test can hold back ({@link #ready}). A copy shares the picture and may be given another size to be drawn at.
 * One made for a frame buffer has storage of the next powers of two, and is let go with {@link #destroy}.
 */
public class Texture implements zombie.interfaces.ITexture {
    /** The picture files there are, by path, with their size. */
    public static final Map<String, Texture> FILES = new HashMap<>();
    /** How many times a picture was asked for by path. */
    public static int loads;
    private final String name;
    private int width, height;
    public boolean ready = true, failed;
    /** Where it is drawn from the place it is drawn at, as the game's (a picture of a texture pack's has one). */
    public float offsetX, offsetY;
    /** The picture a copy shows. */
    public final Texture source;

    public Texture(String name, int width, int height) { this.name = name; this.width = width; this.height = height; source = this; }

    /** Made for a frame buffer: its flags, and the number made. */
    public int flags;
    public boolean destroyed;
    public static int made;

    public Texture(int width, int height, int flags) { this(null, width, height); this.flags = flags; made++; }

    public float getXStart() { return 0; }
    public float getYStart() { return 0; }
    public float getXEnd() { return width / (float)Integer.highestOneBit(Math.max(1, width * 2 - 1)); }
    public float getYEnd() { return height / (float)Integer.highestOneBit(Math.max(1, height * 2 - 1)); }
    public void destroy() { destroyed = true; }

    public Texture(Texture original) {
        name = original.name;
        width = original.width;
        height = original.height;
        source = original.source;
    }

    public static Texture getSharedTexture(String name, int flags) {
        loads++;
        return FILES.get(name);
    }

    public boolean isReady() { return ready && !failed; }
    public boolean isFailure() { return failed; }
    public String getName() { return name; }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public void setWidth(int width) { this.width = width; }
    public void setHeight(int height) { this.height = height; }
}
