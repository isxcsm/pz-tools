package zombie;

import java.util.ArrayList;
import java.util.List;
import zombie.characters.IsoZombie;

/** Synthetic: the sounds zombies hear. The loudest a zombie may hear wins (the game weighs distance, rooms and hearing too). */
public final class WorldSoundManager {
    public static final WorldSoundManager instance = new WorldSoundManager();
    public final List<WorldSound> soundList = new ArrayList<>();
    private static final ResultBiggestSound resultBiggestSound = new ResultBiggestSound();

    public ResultBiggestSound getBiggestSoundZomb(int x, int y, int z, boolean ignoreBySameType, IsoZombie zombie) {
        WorldSound best = null;
        float most = -1000000f;
        for (int index = 0; index < soundList.size(); index++) {
            WorldSound sound = (WorldSound)soundList.get(index);
            if (sound == null) continue;
            if (sound.volume > most) { most = sound.volume; best = sound; }
        }
        resultBiggestSound.sound = best;
        resultBiggestSound.attract = best == null ? 0f : most;
        return resultBiggestSound;
    }

    public static final class WorldSound {
        public Object source;
        public int x, y, z, radius, volume;
        public boolean sourceIsPlayer;
        public WorldSound(int x, int y, int volume, boolean sourceIsPlayer) { this.x = x; this.y = y; this.volume = volume; this.sourceIsPlayer = sourceIsPlayer; }
    }

    public static final class ResultBiggestSound {
        public WorldSound sound;
        public float attract;
    }
}
