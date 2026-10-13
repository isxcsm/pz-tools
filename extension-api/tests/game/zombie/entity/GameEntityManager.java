package zombie.entity;

import java.util.HashMap;

/**
 * Synthetic: the game's entities by id, and its engine (null without a world). {@link #keep} and {@link #giveBack} do
 * what the game does as a rain collector's chunk unloads and loads again.
 */
public class GameEntityManager {
    private static Engine engine = new Engine();
    private static final HashMap<Long, GameEntity> idToEntityMap = new HashMap<>();

    public static GameEntity GetEntity(long id) { return idToEntityMap.get(id); }

    /** The square unloaded: a meta entity keeps the container running. */
    public static void keep(MetaEntity meta) {
        engine.metas.metaEntities.entities.add(meta);
        idToEntityMap.put(meta.id, meta);
    }

    /** The square loaded again: the container goes back to its object, and the meta entity is released. */
    public static void giveBack(MetaEntity meta) {
        engine.metas.metaEntities.entities.remove(meta);
        idToEntityMap.remove(meta.id);
        meta.fluidContainer = null;
    }
}
