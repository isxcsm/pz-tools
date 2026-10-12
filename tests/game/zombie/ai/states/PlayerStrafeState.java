package zombie.ai.states;

import zombie.ai.State;

/** Synthetic: the state a player is in while moving and aiming. */
public final class PlayerStrafeState extends State {
    private static final PlayerStrafeState INSTANCE = new PlayerStrafeState();
    public static PlayerStrafeState instance() { return INSTANCE; }
}
