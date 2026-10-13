package zombie.ai.states;

import zombie.ai.State;

/** Synthetic: a state that is not walking. */
public final class PlayerClimbState extends State {
    private static final PlayerClimbState INSTANCE = new PlayerClimbState();
    public static PlayerClimbState instance() { return INSTANCE; }
}
