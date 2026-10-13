package org.lwjgl.opengl;

/** Synthetic: the active texture unit. */
public final class GL13 {
    public static void glActiveTexture(int unit) { GL11.active = unit; }

    public static int active() { return GL11.active; }
}
