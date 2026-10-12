package zombie.characters;

import java.util.HashMap;
import java.util.Map;

/** Synthetic: like the game's, {@code remove} is {@code add} of the negative, and {@code set} clamps. */
public class Stats {
    private final Map<CharacterStat, Float> stats = new HashMap<>();
    public float get(CharacterStat stat) { return stats.getOrDefault(stat, 0f); }
    public boolean set(CharacterStat stat, float value) {
        float before = get(stat);
        float clamped = stat.clamp(value);
        stats.put(stat, clamped);
        return clamped != before;
    }
    public boolean add(CharacterStat stat, float delta) { return set(stat, get(stat) + delta); }
    public boolean remove(CharacterStat stat, float amount) { return add(stat, -amount); }
}
