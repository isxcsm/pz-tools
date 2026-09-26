package pztools.bridge.runtime;

import java.lang.ref.WeakReference;
import java.lang.reflect.*;
import java.util.UUID;

/** Game-thread-only life facts; no save DB, metadata writes or retained strong player reference. */
final class LiveCharacter {
    record Facts(String life, String character, String death, String sleep) {
        static final Facts UNKNOWN = new Facts("Unknown", null, null, "Unknown");
    }
    private static Facts facts = Facts.UNKNOWN;
    private Method instance, isDead, isAsleep;
    private Field count;
    private final Object[] none = new Object[0];
    LiveCharacter(ClassLoader loader) {
        try {
            Class<?> player = Class.forName("zombie.characters.IsoPlayer", false, loader);
            instance = player.getMethod("getInstance"); isDead = player.getMethod("isDead");
            count = player.getField("numPlayers");
            // Missing sleep support must not erase independent life/death observations.
            try { isAsleep = player.getMethod("isAsleep"); }
            catch (NoSuchMethodException unavailable) { isAsleep = null; }
        } catch (ReflectiveOperationException | LinkageError unavailable) { instance = null; }
    }
    Facts read(String worldId) {
        if (instance == null) return Facts.UNKNOWN;
        try {
            if (count.getInt(null) != 1) return observe(worldId, null, "Unknown");
            Object player = instance.invoke(null, none);
            String life = player == null ? "Unknown" : (boolean)isDead.invoke(player, none) ? "Dead" : "Alive";
            String sleep = "Unknown";
            if (player != null) {
                if (life.equals("Dead")) sleep = "Awake";
                else if (isAsleep != null) {
                    try { sleep = (boolean)isAsleep.invoke(player, none) ? "Asleep" : "Awake"; }
                    catch (ReflectiveOperationException | RuntimeException unavailable) { /* Life remains valid. */ }
                }
            }
            return observe(worldId, player, life, sleep);
        } catch (ReflectiveOperationException | RuntimeException unavailable) {
            return observe(worldId, null, "Unknown");
        }
    }
    static void disconnect() { pztools.extensions.api.RuntimeCharacterIdentity.disconnect(); }
    static Facts observe(String worldId, Object player, String life) {
        return observe(worldId, player, life, "Unknown");
    }
    private static Facts observe(String worldId, Object player, String life, String sleep) {
        var observed = pztools.extensions.api.RuntimeCharacterIdentity.observe(worldId, player, life);
        if (!facts.life().equals(observed.life()) || !java.util.Objects.equals(facts.character(), observed.character())
                || !java.util.Objects.equals(facts.death(), observed.death()) || !facts.sleep().equals(sleep))
            facts = new Facts(observed.life(), observed.character(), observed.death(), sleep);
        return facts;
    }
}
