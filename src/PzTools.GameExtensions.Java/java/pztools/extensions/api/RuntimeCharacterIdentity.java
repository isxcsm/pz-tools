package pztools.extensions.api;

import java.lang.ref.WeakReference;
import java.util.UUID;

/** Process-resident weak identities survive a compatible bridge payload replacement. Game-thread only. */
public final class RuntimeCharacterIdentity {
    public record Facts(String life, String character, String death) {
        static final Facts UNKNOWN = new Facts("Unknown", null, null);
    }
    private static WeakReference<Object> known = new WeakReference<>(null);
    private static String world, character, death, prior = "Unknown";
    private static Facts facts = Facts.UNKNOWN;
    private static volatile boolean disconnected;
    public static void disconnect() { disconnected = true; }
    public static Facts observe(String worldId, Object player, String life) {
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
