package pztools.bridge.runtime.api;

import java.util.*;

/**
 * One network as its mod defined it, and what the API last worked out about it. The definition changes only through
 * {@link Networks}; the rest is kept by {@link PowerGrid} or {@link WaterGrid}, by its utility. Both run on the game's
 * thread.
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

    /** What a water producer's square holds, as last seen loaded: the amounts and capacities of its fluid containers. */
    record Stored(float amount, float capacity) { }

    final String id, owner, utility, policy;
    /** The network whose producers supply this one, which then has none of its own; null for a network with its own. */
    String parent;
    /** In order: under {@code "sequential"} the next that can run takes over when the one in use stops. */
    final List<Position> producers = new ArrayList<>();
    /** Squares that name the member buildings. */
    final List<Position> buildings = new ArrayList<>();
    final Set<Thing> excluded = new LinkedHashSet<>(), included = new LinkedHashSet<>();
    /** Switched off, it has no supply, nor have its children; its producer in use carries no load. */
    boolean enabled = true;
    /** What its load, its children's included, is multiplied by on its way to the producer: 1 for none. */
    float loadFactor = 1f;
    /**
     * The hours it was switched on (true) and off (false) since it was defined, kept for food as {@link #history} is;
     * {@code enabledBefore} is whether it was on before the first.
     */
    final NavigableMap<Double, Boolean> switches = new TreeMap<>();
    boolean enabledBefore = true;

    // Worked out by the grid of its utility.
    /** The member buildings as last resolved, by their BuildingDef's identity. */
    List<Buildings.Building> resolved = List.of();
    Members.Area area;
    /** Each power producer as last seen loaded. */
    final Map<Position, Seen> seen = new HashMap<>();
    /** Each water producer as last seen loaded. */
    final Map<Position, Stored> stored = new HashMap<>();
    /** Each running producer before the game's last hourly update of it. */
    final Map<Position, Settled> settled = new HashMap<>();
    /** The producer that carries the load; null when the network has none running, and always for a child. */
    Position inUse;
    /**
     * Whether it has supply: for power, its producer in use runs; for water, one of its producers holds some; for a
     * child, its parent has supply.
     */
    boolean supplied;
    /** The hour its supply last started or stopped. */
    double suppliedAt;
    /**
     * A power network's supply as the API saw it since it first worked the network out: the hours it started (true)
     * and stopped (false), and whether it had supply before the first. Null until then; kept for a network with its
     * own producers.
     */
    NavigableMap<Double, Boolean> history;
    boolean suppliedBefore;
    /** A producer the game ran while the API knew of none in use, until the next frame takes it in. */
    Position adopted;
    /** Each consumer's consumption, as last seen loaded. */
    Map<Thing, Float> consumption = Map.of();
    /** Its own consumers' load; and with its children's, times its load factor. */
    float load, total;
    boolean loadComplete;
    long loadAt;
    volatile boolean loadChanged = true;

    Network(String id, String owner, String utility, String policy) {
        this.id = id; this.owner = owner; this.utility = utility; this.policy = policy;
    }
}
