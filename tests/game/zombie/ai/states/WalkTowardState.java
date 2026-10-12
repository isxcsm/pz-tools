package zombie.ai.states;

import zombie.ai.State;

/** Synthetic: a state a zombie is in. */
public final class WalkTowardState extends State {
    private static final WalkTowardState INSTANCE = new WalkTowardState();
    public static WalkTowardState instance() { return INSTANCE; }
}
