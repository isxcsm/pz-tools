package pztools.bridge.runtime;

import java.lang.ref.WeakReference;
import java.lang.reflect.*;
import java.util.UUID;

/** Game-thread-only life facts; no save DB, metadata writes or retained strong player reference. */
final class LiveCharacter {
    record Facts(String life, String character, String death) {
        static final Facts UNKNOWN = new Facts("Unknown", null, null);
    }
    private static WeakReference<Object> known = new WeakReference<>(null);
    private static String world, character, death, prior = "Unknown";
    private static Facts facts = Facts.UNKNOWN;
    private static volatile boolean disconnected;
    private Method instance, isDead;
    private Field count;
    private final Object[] none = new Object[0];
    LiveCharacter(ClassLoader loader) {
        try {
            Class<?> player = Class.forName("zombie.characters.IsoPlayer", false, loader);
            instance = player.getMethod("getInstance"); isDead = player.getMethod("isDead");
            count = player.getField("numPlayers");
        } catch (ReflectiveOperationException | LinkageError unavailable) { instance = null; }
    }
    Facts read(String worldId) {
        if (instance == null) return Facts.UNKNOWN;
        try {
            if (count.getInt(null) != 1) return observe(worldId, null, "Unknown");
            Object player = instance.invoke(null, none);
            return observe(worldId, player, player == null ? "Unknown" : (boolean)isDead.invoke(player, none) ? "Dead" : "Alive");
        } catch (ReflectiveOperationException | RuntimeException unavailable) {
            return observe(worldId, null, "Unknown");
        }
    }
    static void disconnect() { disconnected = true; }
    static Facts observe(String worldId, Object player, String life) {
        if (disconnected) { prior = "Unknown"; disconnected = false; }
        if (!java.util.Objects.equals(world, worldId)) {
            world = worldId; known.clear(); character = death = null; prior = "Unknown";
        }
        if (player == null || life.equals("Unknown")) { prior = "Unknown"; return facts = Facts.UNKNOWN; }
        if (known.get() != player) {
            known = new WeakReference<>(player); character = id(); death = null; prior = "Unknown";
        }
        if (life.equals("Alive")) death = null;
        else if (prior.equals("Alive")) death = id();
        // Initially dead is a fact, not a new death event. IDs survive subscription reconnects.
        prior = life;
        if (!facts.life().equals(life) || !java.util.Objects.equals(facts.character(), character)
                || !java.util.Objects.equals(facts.death(), death)) facts = new Facts(life, character, death);
        return facts;
    }
    private static String id() { return UUID.randomUUID().toString().replace("-", ""); }
}