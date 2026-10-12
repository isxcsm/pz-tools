package zombie.core.opengl;

import java.util.ArrayList;
import java.util.List;

/** Synthetic: the render thread's own turns. What is queued for it waits for {@link #flush}. */
public final class RenderThread {
    public static final List<Runnable> queued = new ArrayList<>();

    private RenderThread() { }

    public static void queueInvokeOnRenderContext(Runnable run) { queued.add(run); }

    /** Runs what was queued, in order, as the render thread does at its next turn. */
    public static void flush() {
        var runs = new ArrayList<>(queued);
        queued.clear();
        for (Runnable run : runs) run.run();
    }
}
