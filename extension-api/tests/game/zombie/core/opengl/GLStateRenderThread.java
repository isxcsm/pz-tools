package zombie.core.opengl;

/** Synthetic: the render thread's GL state, restored after a pass changed it. */
public final class GLStateRenderThread {
    public static int restores;
    public static void restore() { restores++; }
}
