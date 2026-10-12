package zombie.ai.states;

import zombie.ai.State;

/** Synthetic: a state a zombie is in. */
public final class LungeState extends State {
    private static final LungeState INSTANCE = new LungeState();
    public static LungeState instance() { return INSTANCE; }
}
