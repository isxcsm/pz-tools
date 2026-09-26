package pztools.extensions.runtime;

import pztools.extensions.api.SaveProvider;

/**
 * Optional capability shared by a versioned extension host and its modules.
 * The resident bootstrap continues to use PreparedSave and SaveTask.
 * Steps execute on the game thread and yield to the normal game loop.
 * Commit and cleanup still drain accepted writes off the game thread.
 */
public interface CooperativeCapture extends SaveProvider.PreparedSave {
    boolean advance(long budgetNanos) throws Exception;

    /** Stop creating inputs without discarding writes or calling game code. */
    void abort(Throwable failure);
}
