package zombie.characters;

import zombie.iso.Vector2;

/** Synthetic: the players of this machine are in {@code players}; any other character is not a local player. */
public class IsoPlayer extends IsoGameCharacter {
    public static final IsoPlayer[] players = new IsoPlayer[4];
    /** The heavy load moodle's level, as the test sets it. */
    public int heavyLoad;
    /** The hypothermia moodle's level, the movement the animation gives and whether a cheat zeroes it, as the test sets them. */
    public int hypothermia;
    public float deferredX, deferredY;
    public boolean invisible;
    /** Whether the player sees everyone (a cheat), and the zombies it was offered to be spotted by. */
    public boolean seeEveryone;
    public final java.util.ArrayList<zombie.iso.IsoMovingObject> spotted = new java.util.ArrayList<>();

    public boolean catsEyes;

    public boolean isSeeEveryone() { return seeEveryone; }

    public void TestZombieSpotPlayer(zombie.iso.IsoMovingObject zombie) { spotted.add(zombie); }

    /** The speed along a path, slowed by a heavy load as the game's is. */
    public float getPathSpeed() {
        float speed = 1.0f;
        if (heavyLoad > 0) {
            float load = getInventory().getCapacityWeight();
            float max = getMaxWeight();
            float over = Math.min(2.0f, load / max) - 1.0f;
            speed = speed * (0.65f + 0.35f * (1.0f - over));
        }
        return speed;
    }

    /** The speed scale of the animation of walking through trees: a ranger is faster, running faster still. */
    private float calculateInTreesSpeed() {
        float speed = ranger ? 1.3f : 1.0f;
        if (isRunning()) speed = speed * 1.1f;
        return speed;
    }

    public float treesSpeed() { return calculateInTreesSpeed(); }

    /** The movement the animation gives: the vector is set and returned, and a cheat has it stand still. */
    protected Vector2 getDeferredMovement(Vector2 vector, boolean flag) {
        vector.set(deferredX, deferredY);
        if (invisible) return vector.set(0.0f, 0.0f);
        return vector;
    }

    public Vector2 movement(Vector2 vector) { return getDeferredMovement(vector, false); }
}
