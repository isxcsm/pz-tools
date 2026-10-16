package pzext.api;

import pzext.boot.Hooks;

/**
 * The game's one slot for the square changes ({@link Hooks#setSquareChanges}), shared by whoever of the API listens: the square
 * watches of mods, and the buildings' versions. The slot holds this while anyone listens and is empty otherwise, so that the
 * game's call costs a null test when nobody does.
 */
final class SquareDispatch implements Hooks.SquareChanges {
    private static final SquareDispatch DISPATCH = new SquareDispatch();
    private static volatile Hooks.SquareChanges[] listeners = new Hooks.SquareChanges[0];

    private SquareDispatch() { }

    /** Starts telling the listener (once). Throws a LinkageError in a game whose bootstrap has no such hook. */
    static synchronized void add(Hooks.SquareChanges listener) {
        for (Hooks.SquareChanges known : listeners) if (known == listener) { Hooks.setSquareChanges(DISPATCH); return; }
        Hooks.SquareChanges[] next = java.util.Arrays.copyOf(listeners, listeners.length + 1);
        next[listeners.length] = listener;
        Hooks.setSquareChanges(DISPATCH);
        listeners = next;
    }

    /** Stops telling the listener; the slot is let go with the last. */
    static synchronized void remove(Hooks.SquareChanges listener) {
        int at = -1;
        for (int index = 0; index < listeners.length; index++) if (listeners[index] == listener) at = index;
        if (at >= 0) {
            Hooks.SquareChanges[] next = new Hooks.SquareChanges[listeners.length - 1];
            for (int index = 0, to = 0; index < listeners.length; index++) if (index != at) next[to++] = listeners[index];
            listeners = next;
        }
        if (listeners.length == 0) {
            try { Hooks.setSquareChanges(null); } catch (LinkageError olderBootstrap) { }
        }
    }

    /** Lets the slot go, whoever listens (an API that failed, or is replaced). */
    static synchronized void clear() {
        listeners = new Hooks.SquareChanges[0];
        try { Hooks.setSquareChanges(null); } catch (LinkageError olderBootstrap) { }
    }

    @Override
    public void changed(int x, int y, int z) throws Throwable {
        for (Hooks.SquareChanges listener : listeners) listener.changed(x, y, z);
    }
}
