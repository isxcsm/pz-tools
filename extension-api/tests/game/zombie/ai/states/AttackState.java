package zombie.ai.states;

import zombie.ai.State;

/** Synthetic: a state a zombie is in. */
public final class AttackState extends State {
    private static final AttackState INSTANCE = new AttackState();
    public static AttackState instance() { return INSTANCE; }
}
