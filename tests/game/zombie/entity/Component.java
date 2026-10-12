package zombie.entity;

/** Synthetic: a component of an entity (the game's items are entities), which knows what it belongs to. */
public abstract class Component {
    public Object owner;
    public final Object getGameEntity() { return owner; }
}
