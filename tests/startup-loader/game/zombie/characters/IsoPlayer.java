package zombie.characters;

/** Synthetic: the players of this machine are in {@code players}; any other character is not a local player. */
public class IsoPlayer extends IsoGameCharacter {
    public static final IsoPlayer[] players = new IsoPlayer[4];
    /** The heavy load moodle's level, as the test sets it. */
    public int heavyLoad;

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
}
