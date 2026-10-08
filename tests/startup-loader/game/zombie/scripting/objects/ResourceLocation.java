package zombie.scripting.objects;

/** Synthetic: a registered name, {@code base:moveable}. */
public final class ResourceLocation {
    private final String id;
    private ResourceLocation(String id) { this.id = id; }
    public static ResourceLocation of(String id) { return new ResourceLocation(id.contains(":") ? id : "base:" + id); }
    @Override public String toString() { return id; }
    @Override public boolean equals(Object other) { return other instanceof ResourceLocation location && location.id.equals(id); }
    @Override public int hashCode() { return id.hashCode(); }
}
