package zombie.core.textures;

import java.util.HashMap;
import java.util.Map;

/**
 * Synthetic: a picture. The files there are, by path, are what the test puts in {@link #FILES}; the game reads a file's size as
 * it loads it, which a test can hold back ({@link #ready}). A copy shares the picture and may be given another size to be drawn at.
 */
public class Texture {
    /** The picture files there are, by path, with their size. */
    public static final Map<String, Texture> FILES = new HashMap<>();
    /** How many times a picture was asked for by path. */
    public static int loads;
    private final String name;
    private int width, height;
    public boolean ready = true;
    /** The picture a copy shows. */
    public final Texture source;

    public Texture(String name, int width, int height) { this.name = name; this.width = width; this.height = height; source = this; }

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

    public boolean isReady() { return ready; }
    public String getName() { return name; }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public void setWidth(int width) { this.width = width; }
    public void setHeight(int height) { this.height = height; }
}
