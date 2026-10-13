package zombie.entity;

/** Synthetic: the game's entity engine, with its system of meta entities. */
public final class Engine {
    final MetaEntitySystem metas = new MetaEntitySystem();

    @SuppressWarnings("unchecked")
    public <T> T getSystem(Class<T> type) { return type == MetaEntitySystem.class ? (T)metas : null; }
}
