package zombie.ai.states;

import zombie.ai.State;
import zombie.characters.IsoGameCharacter;
import zombie.characters.IsoZombie;

/** Synthetic: a state a zombie is in; idle, it wanders to a square near it, as the game's (the step is the test's, the game draws it). */
public final class ZombieIdleState extends State {
    private static final ZombieIdleState INSTANCE = new ZombieIdleState();
    public static ZombieIdleState instance() { return INSTANCE; }
    /** The step the next wander takes (the game's is -4 to 3 each way, by chance). */
    public static int stepX, stepY;

    public void execute(IsoGameCharacter character) {
        IsoZombie zombie = (IsoZombie)character;
        int x = (int)Math.floor(zombie.getX()) + stepX;
        int y = (int)Math.floor(zombie.getY()) + stepY;
        zombie.pathToLocation(x, y, (int)Math.floor(zombie.getZ()));
    }
}
