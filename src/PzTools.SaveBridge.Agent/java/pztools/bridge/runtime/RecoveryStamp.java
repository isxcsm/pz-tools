package pztools.bridge.runtime;

import java.lang.reflect.Method;
import java.util.UUID;

/** Stable save metadata copied by the game from player to corpse to reanimated player. */
public final class RecoveryStamp {
    private RecoveryStamp() { }
    public static void record(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> type = Class.forName("zombie.characters.IsoPlayer", false, loader);
        Object player = type.getMethod("getInstance").invoke(null);
        if (player == null || (boolean)type.getMethod("isDead").invoke(player)) return;
        Object data = type.getMethod("getModData").invoke(player);
        Method read = data.getClass().getMethod("rawget", Object.class);
        Method write = data.getClass().getMethod("rawset", Object.class, Object.class);
        Object existing = read.invoke(data, "pztools.recovery.id");
        String identity = null;
        if (existing instanceof String text) {
            try { identity = UUID.fromString(text).toString(); } catch (IllegalArgumentException ignored) { }
        }
        if (identity == null) identity = UUID.randomUUID().toString();
        int primary = itemId(type.getMethod("getPrimaryHandItem").invoke(player));
        int secondary = itemId(type.getMethod("getSecondaryHandItem").invoke(player));
        write.invoke(data, "pztools.recovery.primary", (double)primary);
        write.invoke(data, "pztools.recovery.secondary", (double)secondary);
        write.invoke(data, "pztools.recovery.id", identity);
    }
    private static int itemId(Object item) throws ReflectiveOperationException {
        return item == null ? -1 : ((Number)item.getClass().getMethod("getID").invoke(item)).intValue();
    }
}
