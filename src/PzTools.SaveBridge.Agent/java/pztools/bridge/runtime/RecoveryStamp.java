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
    /**
     * Only the character ID, and only when the living player has none: called by the runtime observer
     * so that a character who dies before their first backup is still recognisable. The game copies the
     * player's modData to the corpse and the zombie, so the in-memory value is enough. Hand items are
     * left to {@link #record}, at the save they describe.
     */
    public static void ensureIdentity(Object player) throws ReflectiveOperationException {
        Object data = player.getClass().getMethod("getModData").invoke(player);
        if (data == null) return;
        Object existing = data.getClass().getMethod("rawget", Object.class).invoke(data, "pztools.recovery.id");
        String identity = null;
        if (existing instanceof String text) {
            try { identity = UUID.fromString(text).toString(); } catch (IllegalArgumentException invalid) { }
            if (text.equals(identity)) return;
        }
        // As record does: an unreadable value is replaced, a readable one written in canonical form.
        data.getClass().getMethod("rawset", Object.class, Object.class)
            .invoke(data, "pztools.recovery.id", identity != null ? identity : UUID.randomUUID().toString());
    }
    private static int itemId(Object item) throws ReflectiveOperationException {
        return item == null ? -1 : ((Number)item.getClass().getMethod("getID").invoke(item)).intValue();
    }
}
