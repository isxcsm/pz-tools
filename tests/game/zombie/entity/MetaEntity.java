package zombie.entity;

/**
 * Synthetic: what keeps an object's components running while its square is not loaded, at the object's position.
 * A test puts one in the engine's bucket and under its id with {@link GameEntityManager#keep}.
 */
public class MetaEntity extends GameEntity {
    public final long id;
    public final float x, y, z;
    public Component fluidContainer;

    public MetaEntity(long id, float x, float y, float z, Component fluidContainer) {
        this.id = id; this.x = x; this.y = y; this.z = z; this.fluidContainer = fluidContainer;
    }

    @Override public long getEntityNetID() { return id; }
    @Override public float getX() { return x; }
    @Override public float getY() { return y; }
    @Override public float getZ() { return z; }
    @SuppressWarnings("unchecked")
    @Override public <T extends Component> T getComponent(ComponentType type) {
        return type == ComponentType.FluidContainer ? (T)fluidContainer : null;
    }
}
