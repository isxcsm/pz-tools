package zombie.ai.states.player;

import zombie.ai.State;

/** Synthetic: the state a player is in while walking or running. */
public final class PlayerMovementState extends State {
    private static final PlayerMovementState INSTANCE = new PlayerMovementState();
    public static PlayerMovementState instance() { return INSTANCE; }
}
