package org.lwjgl.opengl;

import java.nio.ByteBuffer;

/** Synthetic: the textures made, the one bound, its size and the bytes last put into it (four a texel for RGBA, else two); the active unit (GL13). */
public final class GL11 {
    public static int made, bound, width, height, unitBound = -1;
    public static byte[] pixels;
    static int active = 0x84C0;

    public static int glGenTextures() { return ++made; }

    public static void glBindTexture(int target, int texture) { bound = texture; unitBound = active; }

    public static void glTexParameteri(int target, int name, int value) { }

    public static void glTexImage2D(int target, int level, int format, int width, int height, int border, int pixelFormat, int type, ByteBuffer data) {
        GL11.width = width;
        GL11.height = height;
        pixels = new byte[width * height * (pixelFormat == 0x1908 ? 4 : 2)];
    }

    public static void glTexSubImage2D(int target, int level, int x, int y, int width, int height, int format, int type, ByteBuffer data) {
        for (int i = 0; i < data.capacity(); i++) pixels[i] = data.get(i);
    }

    public static int glGetInteger(int name) { return name == 0x84E0 ? active : 0; }

    /**
     * The viewport and the scissor test, as a frame buffer's drawing changes and puts them back; the picture read back: its alpha
     * at a texel (from the bottom row up) as the test says, 0 without; the size last read.
     */
    public static final int[] viewport = { 0, 0, 1600, 900 };
    public static boolean scissor;
    public static java.util.function.IntBinaryOperator ink;
    public static int readWidth, readHeight;

    public static void glGetIntegerv(int name, int[] values) { if (name == 0x0BA2) System.arraycopy(viewport, 0, values, 0, 4); }

    public static void glViewport(int x, int y, int width, int height) {
        viewport[0] = x; viewport[1] = y; viewport[2] = width; viewport[3] = height;
        if (zombie.ui.TextManager.record) zombie.ui.TextManager.log("viewport", x, y, width, height);
    }

    public static boolean glIsEnabled(int capability) { return capability == 0x0C11 && scissor; }
    public static void glEnable(int capability) { if (capability == 0x0C11) scissor = true; }
    public static void glDisable(int capability) { if (capability == 0x0C11) scissor = false; }
    public static void glPixelStorei(int name, int value) { }
    // Pushed and not yet popped attribute sets.
    public static int pushed;
    public static void glPushClientAttrib(int mask) { pushed++; }
    public static void glPushAttrib(int mask) { pushed++; }
    public static void glPopAttrib() { pushed--; }
    public static void glPopClientAttrib() { pushed--; }
    public static void glBlendFunc(int source, int target) { }
    public static void glAlphaFunc(int function, float reference) { }
    public static int glGetError() { return 0; }

    public static void glReadPixels(int x, int y, int width, int height, int format, int type, ByteBuffer pixels) {
        readWidth = width;
        readHeight = height;
        if (zombie.ui.TextManager.record) zombie.ui.TextManager.log("read", width, height);
        for (int row = 0; row < height; row++)
            for (int column = 0; column < width; column++) {
                int at = (row * width + column) * 4;
                pixels.put(at, (byte)255).put(at + 1, (byte)255).put(at + 2, (byte)255);
                pixels.put(at + 3, (byte)(ink == null ? 0 : ink.applyAsInt(x + column, y + row)));
            }
    }
}
