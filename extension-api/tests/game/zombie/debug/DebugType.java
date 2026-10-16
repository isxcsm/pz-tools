package zombie.debug;

import java.util.ArrayList;
import java.util.List;

/** Synthetic: the game's log channels. What a channel reports as an error is kept, for a test to read. */
public enum DebugType {
    General;

    /** What the game complained of, in order. */
    public static final List<String> errors = new ArrayList<>();

    public void error(Object message) { errors.add(String.valueOf(message)); }
}
