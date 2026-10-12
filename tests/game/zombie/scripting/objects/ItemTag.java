package zombie.scripting.objects;

import java.util.HashMap;
import java.util.Map;

/** Synthetic: the game's item tags are registered objects, found by their location. */
public final class ItemTag {
    private static final Map<ResourceLocation, ItemTag> REGISTRY = new HashMap<>();
    public static final ItemTag KEY_RING = register("base:keyring");
    public static final ItemTag HEAVY_ITEM = register("base:heavyitem");
    public static final ItemTag SCREWDRIVER = register("base:screwdriver");
    private final String name;
    private ItemTag(String name) { this.name = name; }
    private static ItemTag register(String id) {
        var tag = new ItemTag(id);
        REGISTRY.put(ResourceLocation.of(id), tag);
        return tag;
    }
    public static ItemTag get(ResourceLocation location) { return REGISTRY.get(location); }
    @Override public String toString() { return name; }
}
