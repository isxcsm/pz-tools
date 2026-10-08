package zombie.iso;

import zombie.characters.IsoGameCharacter;

/**
 * Synthetic: the game's helicopter. Its state is written in several places, as the game's is: when a target is set, in
 * changeState, straight in update, when a save loads, and the helicopter is taken off by deactivate. The state is an
 * enum the game does not make public.
 */
public class Helicopter {
    enum State { Arriving, Hovering, Searching, Leaving }

    protected State state;
    public IsoGameCharacter target;
    public float x, y;
    protected boolean active;

    public boolean isActive() { return active; }

    public void setTarget(IsoGameCharacter character) {
        target = character;
        x = character.getX() + 1000f;
        y = character.getY() + 1000f;
        state = State.Arriving;
        active = true;
    }

    protected void changeState(State next) { state = next; }

    public void deactivate() { active = false; }

    /** What update does: a state through changeState, the helicopter moving, a state written straight, a save loaded. */
    public void update(String next, float newX, float newY) { changeState(State.valueOf(next)); x = newX; y = newY; }

    public void leaveAtOnce() { state = State.Leaving; }

    public void load(String saved, boolean flying) { state = State.valueOf(saved); active = flying; }
}
