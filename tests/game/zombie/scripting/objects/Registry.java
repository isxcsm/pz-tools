package zombie.scripting.objects;

import java.util.*;

/** Synthetic: the game's registry of objects by location, which refuses a duplicate and, reset, keeps only the base namespace. */
public class Registry<T> {
    private final Map<ResourceLocation, T> byLocation = new HashMap<>();
    private final Map<T, ResourceLocation> byObject = new IdentityHashMap<>();
    private final List<T> values = new ArrayList<>();
    private final String name;

    public Registry(String name) { this.name = name; }

    public ResourceLocation getLocation(T value) { return byObject.get(value); }

    public T register(ResourceLocation id, T value) {
        ResourceLocation oldId = byObject.put(value, id);
        T old = byLocation.put(id, value);
        values.add(value);
        if (old != null || oldId != null) throw new IllegalArgumentException("Tried to register duplicate object: %s in: %s".formatted(id, name));
        return value;
    }

    public T get(ResourceLocation id) { return byLocation.get(id); }

    public List<T> values() { return Collections.unmodifiableList(values); }

    protected void reset() {
        var gone = new HashSet<T>();
        for (var entry : byObject.entrySet()) if (!entry.getValue().getNamespace().equals("base")) gone.add(entry.getKey());
        byObject.keySet().removeAll(gone);
        byLocation.values().removeIf(gone::contains);
        values.removeAll(gone);
    }
}
