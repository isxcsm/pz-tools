package zombie.ai.states;

import zombie.ai.State;

/** Synthetic: a state a zombie is in. */
public final class ZombieIdleState extends State {
    private static final ZombieIdleState INSTANCE = new ZombieIdleState();
    public static ZombieIdleState instance() { return INSTANCE; }
}
