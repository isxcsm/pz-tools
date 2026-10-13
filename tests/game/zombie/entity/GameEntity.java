package zombie.entity;

/** Synthetic: what the game's entities share, as the API reads a meta entity. */
public abstract class GameEntity {
    public abstract long getEntityNetID();
    public abstract float getX();
    public abstract float getY();
    public abstract float getZ();
    public abstract <T extends Component> T getComponent(ComponentType type);
}
