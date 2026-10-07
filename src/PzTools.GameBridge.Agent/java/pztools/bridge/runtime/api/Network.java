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

    /**
     * A producer: a square with a generator or a water container on it, or a source that its mod runs (power only),
     * named by the mod. Exactly one of the two is set.
     */
    record Producer(Position at, String source) {
        static Producer square(Position at) { return new Producer(at, null); }
        static Producer source(String name) { return new Producer(null, name); }
    }

    /**
     * A source as its mod last set it: whether it can carry the load, whether it is switched on, and the hour it last
     * became unable to (NaN when the mod gave none).
     */
    static final class Source {
        boolean available, on;
        double stoppedAt = Double.NaN;
    }

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

    /**
     * What a water producer's square holds, as last seen loaded: the amounts and capacities of its fluid containers, the
     * litres of each fluid in them, by the game's name for it, and the sequence number of the last change owed to the
     * square that they took (PendingFluids; Long.MIN_VALUE for none).
     */
    record Stored(float amount, float capacity, Map<String, Float> fluids, long taken) { }

    final String id, owner, utility, policy;
    /**
     * The network whose producers supply this one: for power, a child has none of its own; for water, it draws from its
     * own and then its parents'. Null for a network at the top.
     */
    String parent;
    /** In order: under {@code "sequential"} the next that can run takes over when the one in use stops. */
    final List<Producer> producers = new ArrayList<>();
    /** The sources among the producers, by name. */
    final Map<String, Source> sources = new HashMap<>();
    /** Squares that name the member buildings, and squares that name single member rooms. */
    final List<Position> buildings = new ArrayList<>(), rooms = new ArrayList<>();
    final Set<Thing> excluded = new LinkedHashSet<>(), included = new LinkedHashSet<>();
    /** Switched off, it has no supply, nor have its children; its producer in use carries no load. */
    boolean enabled = true;
    /** What its load, its children's included, is multiplied by on its way to the producer: 1 for none. */
    float loadFactor = 1f;
    /** A load its mod adds to its consumers' (power only). */
    float extraLoad;
    /** Whether its fixtures get their water purified, as the game purifies plumbed water (water only). */
    boolean purify = true;
    /**
     * The hours it was switched on (true) and off (false) since it was defined, kept for food as {@link #history} is;
     * {@code enabledBefore} is whether it was on before the first.
     */
    final NavigableMap<Double, Boolean> switches = new TreeMap<>();
    boolean enabledBefore = true;

    // Worked out by the grid of its utility.
    /** The member buildings as last resolved, by their BuildingDef's identity; one named by rooms alone has those. */
    List<Buildings.Building> resolved = List.of();
    Members.Area area;
    /** Each power producer as last seen loaded; a source as its mod last set it. */
    final Map<Producer, Seen> seen = new HashMap<>();
    /** Each water producer as last seen loaded. */
    final Map<Position, Stored> stored = new HashMap<>();
    /** Each running producer before the game's last hourly update of it. */
    final Map<Position, Settled> settled = new HashMap<>();
    /**
     * The generators out of service: the API saw each switched off by hand, and has not seen it run since (see
     * PowerGrid.OUT_OF_SERVICE). The API never switches them on. Every other generator that is off is on standby.
     */
    final Set<Producer> outOfService = new HashSet<>();
    /** The squares of generators the game ran since the last frame (see PowerGrid.generatorUpdate). */
    final Set<Position> ran = new HashSet<>();
    /**
     * Producers a payload from before the marks handed over: the next frame reads their marks as at first sight, which
     * that payload did not keep.
     */
    final Set<Producer> recheck = new HashSet<>();
    /**
     * Power, at the top of its parents: whether the API stopped its producers as it was switched off (and has not
     * started one since it was switched on again: it may wait for the square of the one to start first to load), and
     * the producer to start first as it is switched on again: the one in use when it was switched off, or one a player
     * or a source's mod switched on meanwhile. Null for none, and whenever it is not stopped.
     */
    boolean stopped;
    Producer resume;
    /** The producer that carries the load; null when the network has none running, and always for a child. */
    Producer inUse;
    /**
     * Whether it has supply: for power, its producer in use runs, and for a child, its parent has supply; for water, one
     * of the producers it draws from, its own or its parents', holds some.
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
    Producer adopted;
    /** Each consumer's consumption, as last seen loaded. */
    Map<Thing, Float> consumption = Map.of();
    /** Its own consumers' load and its extra load; and with its children's, times its load factor. */
    float load, total;
    boolean loadComplete;
    long loadAt;
    volatile boolean loadChanged = true;

    Network(String id, String owner, String utility, String policy) {
        this.id = id; this.owner = owner; this.utility = utility; this.policy = policy;
    }

    /** The squares of its producers, in order: all but its sources. */
    List<Position> squares() {
        var result = new ArrayList<Position>();
        for (Producer producer : producers) if (producer.at() != null) result.add(producer.at());
        return result;
    }
}
