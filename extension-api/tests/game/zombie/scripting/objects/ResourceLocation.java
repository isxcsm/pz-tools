package zombie.scripting.objects;

import java.util.Locale;
import java.util.Objects;

/** Synthetic: a registered name, {@code base:moveable}, as the game's: a namespace (base when none is given) and a path, lower case. */
public final class ResourceLocation {
    public static final String DEFAULT_NAMESPACE = "base";
    private final String namespace, path;

    public ResourceLocation(String namespace, String path) {
        if (namespace == null || namespace.isEmpty()) throw new IllegalArgumentException("Namespace cannot be null or empty");
        if (path == null || path.isEmpty()) throw new IllegalArgumentException("Path cannot be null or empty");
        this.namespace = namespace.toLowerCase(Locale.ENGLISH);
        this.path = path.toLowerCase(Locale.ENGLISH);
    }

    public static ResourceLocation of(String id) {
        if (id == null || id.isEmpty()) throw new IllegalArgumentException("Identifier cannot be null or empty");
        String[] parts = id.split(":", 2);
        return parts.length == 1 ? new ResourceLocation(DEFAULT_NAMESPACE, parts[0]) : new ResourceLocation(parts[0], parts[1]);
    }

    public String getNamespace() { return namespace; }
    public String getPath() { return path; }
    @Override public String toString() { return namespace + ":" + path; }
    @Override public boolean equals(Object other) {
        return other instanceof ResourceLocation location && location.namespace.equals(namespace) && location.path.equals(path);
    }
    @Override public int hashCode() { return Objects.hash(namespace, path); }
}
