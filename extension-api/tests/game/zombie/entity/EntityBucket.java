package zombie.entity;

import zombie.entity.util.ImmutableArray;

/** Synthetic: the entities of a family, as the game keeps them. */
public class EntityBucket {
    final java.util.ArrayList<GameEntity> entities = new java.util.ArrayList<>();
    public final ImmutableArray<GameEntity> getEntities() { return new ImmutableArray<>(entities); }
}
