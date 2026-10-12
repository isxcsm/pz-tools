package zombie.scripting.objects;

/** Synthetic: what the game does to its registries as it leaves a world or reloads its Lua. */
public class RegistryReset {
    public static void resetAll() { Registries.MOODLE_TYPE.reset(); }

    public static ResourceLocation createLocation(String id, boolean allowsBaseNamespace) {
        ResourceLocation location = ResourceLocation.of(id);
        if (!allowsBaseNamespace && "base".equals(location.getNamespace()))
            throw new IllegalArgumentException(String.format("Default namespace '%s' is not allowed!", location));
        return location;
    }
}
