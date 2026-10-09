package org.lwjgl.opengl;

import java.nio.ByteBuffer;

/** Synthetic: the textures made, the one bound, its size and the bytes last put into it (two a texel); the active unit (GL13). */
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
        pixels = new byte[width * height * 2];
    }

    public static void glTexSubImage2D(int target, int level, int x, int y, int width, int height, int format, int type, ByteBuffer data) {
        for (int i = 0; i < data.capacity(); i++) pixels[i] = data.get(i);
    }

    public static int glGetInteger(int name) { return name == 0x84E0 ? active : 0; }
}
