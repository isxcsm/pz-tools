package zombie.audio.parameters;

import zombie.characters.IsoZombie;

/** Synthetic: the state a zombie's voice is played in, set as the game sets it (an early return for the same state). */
public final class ParameterZombieState {
    private final IsoZombie zombie;
    private State state = State.Idle;

    public ParameterZombieState(IsoZombie zombie) { this.zombie = zombie; }

    /** The game's own: with a target, a calm zombie searches; without one, a searching zombie is calm again. */
    public float calculateCurrentValue() {
        if (zombie.target == null) { if (state == State.SearchTarget) setState(State.Idle); }
        else if (state == State.Idle) setState(State.SearchTarget);
        return state.index;
    }

    public void setState(State next) {
        if (next == state) return;
        state = next;
    }

    public boolean isState(State value) { return state == value; }

    public enum State {
        Idle(0), Eating(1), SearchTarget(2), LockTarget(3), AttackScratch(4), AttackLacerate(5), AttackBite(6), Hit(7), Death(8),
        Reanimate(9), Pushed(10), GettingUp(11), Attack(12), RunOver(13);

        final int index;

        State(int index) { this.index = index; }
    }
}
