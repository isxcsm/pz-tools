package pztools.bridge.runtime.api;

import java.util.*;

/**
 * One network as its mod defined it, and what the API last worked out about it. The definition changes only through
 * {@link Networks}; the rest is kept by {@link PowerGrid}. Both run on the game's thread.
 */
final class Network {
    /** A square. */
    record Position(int x, int y, int z) {
        static Position parse(String text) {
            String[] parts = text.split(",", -1);
            return new Position(Integer.parseInt(parts[0]), Integer.parseInt(parts[1]), Integer.parseInt(parts[2]));
        }

        @Override public String toString() { return x + "," + y + "," + z; }
    }

    /** An object, named by its square and its sprite. */
    record Thing(Position at, String sprite) { }

    /** A producer as last seen loaded. */
    record Seen(boolean activated, float fuel, int condition) {
        boolean canRun() { return fuel > 0 && condition > 0; }
    }

    /**
     * A running producer before the game's hourly update: the hour it has burned up to, its fuel, and what it burns an
     * hour. The game burns hour by hour and stops it in the hour its fuel runs out.
     */
    record Settled(int lastHour, float fuel, float perHour) {
        double end() { return perHour > 0 ? lastHour + Math.ceil(fuel / perHour) : Double.POSITIVE_INFINITY; }
    }

    final String id, owner, utility, policy;
    /** In order: under {@code "sequential"} the next that can run takes over when the one in use stops. */
    final List<Position> producers = new ArrayList<>();
    /** Squares that name the member buildings. */
    final List<Position> buildings = new ArrayList<>();
    final Set<Thing> excluded = new LinkedHashSet<>(), included = new LinkedHashSet<>();

    // Worked out by PowerGrid.
    /** The member buildings as last resolved, by their BuildingDef's identity. */
    List<Buildings.Building> resolved = List.of();
    PowerGrid.Area area;
    /** Each producer as last seen loaded. */
    final Map<Position, Seen> seen = new HashMap<>();
    /** Each running producer before the game's last hourly update of it. */
    final Map<Position, Settled> settled = new HashMap<>();
    /** The producer that carries the load; null when the network has no supply. */
    Position inUse;
    /** A producer the game ran while the API knew of none in use, until the next frame takes it in. */
    Position adopted;
    /** Each consumer's consumption, as last seen loaded. */
    Map<Thing, Float> consumption = Map.of();
    float load;
    boolean loadComplete;
    long loadAt;
    volatile boolean loadChanged = true;

    Network(String id, String owner, String utility, String policy) {
        this.id = id; this.owner = owner; this.utility = utility; this.policy = policy;
    }
}
