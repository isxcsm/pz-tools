package zombie.popman;

import java.util.ArrayList;
import java.util.List;
import zombie.characters.IsoZombie;
import zombie.iso.IsoChunk;

/**
 * Synthetic: as a chunk unloads, its zombies become virtual (the population keeps their place and number): a moving one and a
 * standing one go through their own n_addZombie, as in the game. releaseZombie lets one go from the population.
 */
public final class ZombiePopulationManager {
    public static final ZombiePopulationManager instance = new ZombiePopulationManager();
    /** The zombies on the chunk the test unloads, the numbers kept virtual, and the numbers let go. */
    public final List<Object> onChunk = new ArrayList<>();
    public static final List<Integer> virtual = new ArrayList<>(), released = new ArrayList<>();

    public void removeChunkFromWorld(IsoChunk chunk) {
        for (int index = 0; index < onChunk.size(); index++) {
            Object moving = onChunk.get(index);
            if (!(moving instanceof IsoZombie)) continue;
            IsoZombie zombie = (IsoZombie)moving;
            if (zombie.pathX != Integer.MIN_VALUE)
                n_addZombie(zombie.getX(), zombie.getY(), zombie.getZ(), (byte)0, 0, zombie.pathX, zombie.pathY, 0, zombie.persistentId);
            else n_addZombie(zombie.getX(), zombie.getY(), zombie.getZ(), (byte)0, 0, Integer.MIN_VALUE, Integer.MIN_VALUE, 0, zombie.persistentId);
        }
        onChunk.clear();
    }

    private static void n_addZombie(float x, float y, float z, byte direction, int outfit, int pathX, int pathY, int flags, int id) {
        virtual.add(id);
    }

    public static void releaseZombie(IsoZombie zombie) { released.add(zombie.persistentId); }
}
