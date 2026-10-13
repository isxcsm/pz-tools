package zombie.scripting.objects;

import java.util.HashMap;
import java.util.Map;

/** Synthetic: the game's item types are registered objects, found by their location. */
public final class ItemType {
    private static final Map<ResourceLocation, ItemType> REGISTRY = new HashMap<>();
    public static final ItemType NORMAL = register("base:normal");
    public static final ItemType MOVEABLE = register("base:moveable");
    public static final ItemType KEY_RING = register("base:keyring");
    private final String name;
    private ItemType(String name) { this.name = name; }
    private static ItemType register(String id) {
        var type = new ItemType(id);
        REGISTRY.put(ResourceLocation.of(id), type);
        return type;
    }
    public static ItemType get(ResourceLocation location) { return REGISTRY.get(location); }
    @Override public String toString() { return name; }
}
