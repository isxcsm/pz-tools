package pztools.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.regex.Pattern;

/**
 * {@code PZToolsAPI.zombies}: a query over the zombies the cell holds, for sensing mods. One pass over the game's list
 * (the loaded, real zombies: a zombie that has not been made yet is not in it), asked each zombie's position through
 * handles that are constants, with nothing allocated for a zombie that is not near, so that a bigger radius costs no more.
 * A call with options (levels, who sees the zombie, who it hunts, its state, crawling) goes through the same list with the
 * same handles; one without them is the pass it always was.
 */
final class Zombies {
    static final int MAX_LEVEL = 64, MAX_LIMIT = 64, DEFAULT_LIMIT = 8, MAX_LEVELS = 16, MAX_STATES = 16;
    static final double MAX_RADIUS = 1000;
    private static final String AREA = "PZToolsAPI.zombies.";
    /** Where the game keeps the classes of its states ({@code zombie.ai.states.LungeState}). */
    private static final String STATES = "zombie.ai.states.";
    private static final Pattern STATE_NAME = Pattern.compile("[A-Za-z0-9_]{1,64}");

    private final Kahlua lua;
    private final Game game;
    private final Players players;
    private final ClassLoader loader;
    // The game's State objects by the name a mod gave, found once.
    private final HashMap<String, Object> states = new HashMap<>();

    Zombies(Kahlua lua, Game game, ClassLoader loader) throws ReflectiveOperationException {
        ZombieReads.use(loader);
        this.lua = lua;
        this.game = game;
        this.loader = loader;
        players = new Players(loader);
    }

    /** Sets this area's functions into its table, replacing those of an earlier API. */
    void register(Object table) throws ReflectiveOperationException {
        lua.set(table, "near", lua.function(AREA + "near", this::near));
    }

    /**
     * What a call with options asks for besides the position. Everything but {@code levels} is left out (null, or -1) when the
     * call does not ask.
     */
    private static final class Query {
        int[] levels;
        // The player's index in IsoPlayer.players for seenBy, or -1; and whether the zombies wanted are seen by it (null: either).
        int seenBy = -1;
        Boolean seen, hunting, crawling;
        // A character the wanted zombies hunt (their target is it).
        Object targeting;
        // The game's State objects the wanted zombies are in one of (null: any state).
        Object[] inState;
        // A table to put the list in, whose entries are used again.
        Object into;
    }

    /**
     * {@code zombies.near(x, y, z, radius, limit, options)}: how many living zombies stand on level {@code z} within {@code radius}
     * squares of the point, and the nearest {@code limit} of them (8 when it is left out, 0 to 64) nearest first, each a
     * table of {@code zombie}, {@code x}, {@code y}, {@code z} and {@code distance}. With {@code options} (a table; see
     * {@link #query}) the zombies are narrowed, and each carries what the game says of it besides.
     */
    private Object[] near(Object[] arguments) throws Exception {
        String call = AREA + "near";
        double x = Arguments.number(arguments, 0, call, "x", -1e9, 1e9), y = Arguments.number(arguments, 1, call, "y", -1e9, 1e9);
        Object options = arguments.length > 5 ? arguments[5] : null;
        if (options != null && !lua.isTable(options)) throw new IllegalArgumentException(call + ": options must be a table");
        Query query = options == null ? null : query(options, call);
        // With levels of its own the call needs no z.
        int level = query != null && query.levels != null ? 0 : Arguments.integer(arguments, 2, call, "z", -MAX_LEVEL, MAX_LEVEL);
        double radius = Arguments.number(arguments, 3, call, "radius", 0, MAX_RADIUS);
        int limit = arguments.length > 4 && arguments[4] != null ? Arguments.integer(arguments, 4, call, "limit", 0, MAX_LIMIT) : DEFAULT_LIMIT;
        Object into = query == null ? null : query.into;
        Object result = into != null ? into : lua.table();
        Object cell = game.cell();
        if (cell == null) {
            if (into != null) trim(into, 0);
            return new Object[] { 0.0, result };
        }
        Object[] nearest = new Object[limit];
        double[] squared = new double[limit];
        int kept = 0, count = 0;
        try {
            ArrayList<?> zombies = (ArrayList<?>)ZombieReads.Handles.LIST.invokeExact(cell);
            double within = radius * radius;
            for (int at = 0, size = zombies.size(); at < size; at++) {
                Object zombie = zombies.get(at);
                double dx = (float)ZombieReads.Handles.X.invokeExact(zombie) - x, dy = (float)ZombieReads.Handles.Y.invokeExact(zombie) - y;
                double distance = dx * dx + dy * dy;
                if (distance > within || !onLevel(query, level, floor((float)ZombieReads.Handles.Z.invokeExact(zombie)))
                        || (boolean)ZombieReads.Handles.DEAD.invokeExact(zombie)) continue;
                if (query != null && !wanted(query, zombie)) continue;
                count++;
                if (limit == 0 || kept == limit && distance >= squared[kept - 1]) continue;
                // Into place among the nearest, dropping the farthest when they are full.
                int place = kept < limit ? kept++ : kept - 1;
                while (place > 0 && squared[place - 1] > distance) { nearest[place] = nearest[place - 1]; squared[place] = squared[place - 1]; place--; }
                nearest[place] = zombie;
                squared[place] = distance;
            }
            for (int index = 0; index < kept; index++) {
                Object entry = into == null ? null : lua.get(into, (double)(index + 1));
                if (!lua.isTable(entry)) entry = lua.table();
                lua.set(entry, "zombie", nearest[index]);
                lua.set(entry, "x", (double)(float)ZombieReads.Handles.X.invokeExact(nearest[index]));
                lua.set(entry, "y", (double)(float)ZombieReads.Handles.Y.invokeExact(nearest[index]));
                lua.set(entry, "z", (double)floor((float)ZombieReads.Handles.Z.invokeExact(nearest[index])));
                lua.set(entry, "distance", Math.sqrt(squared[index]));
                if (query != null) describe(query, entry, nearest[index]);
                lua.set(result, (double)(index + 1), entry);
            }
            if (into != null) trim(into, kept);
        } catch (Exception | Error failure) {
            throw failure;
        } catch (Throwable failure) {
            throw Game.failed(Game.thrown(failure));
        }
        return new Object[] { (double)count, result };
    }

    /** Whether the zombie's level is one wanted: the call's own, or one of the options'. */
    private static boolean onLevel(Query query, int level, int floor) {
        if (query == null || query.levels == null) return floor == level;
        for (int wanted : query.levels) if (wanted == floor) return true;
        return false;
    }

    /** Whether a zombie is one the options ask for. */
    private static boolean wanted(Query query, Object zombie) throws Throwable {
        if (query.crawling != null && (boolean)ZombieReads.Filters.CRAWLING.invokeExact(zombie) != query.crawling) return false;
        if (query.hunting != null || query.targeting != null) {
            Object target = (Object)ZombieReads.Filters.TARGET.invokeExact(zombie);
            if (query.hunting != null && (target != null) != query.hunting) return false;
            if (query.targeting != null && target != query.targeting) return false;
        }
        if (query.inState != null) {
            Object current = (Object)ZombieReads.Filters.STATE.invokeExact(zombie);
            boolean in = false;
            for (Object state : query.inState) if (state == current) { in = true; break; }
            if (!in) return false;
        }
        return query.seen == null || ((boolean[])ZombieReads.Handles.VISIBLE.invokeExact(zombie))[query.seenBy] == query.seen;
    }

    /** What the game says of a zombie that was asked about: its state's name, whether it crawls, whether it hunts, and who sees it. */
    private void describe(Query query, Object entry, Object zombie) throws Throwable {
        Object state = (Object)ZombieReads.Filters.STATE.invokeExact(zombie);
        lua.set(entry, "state", state == null ? null : state.getClass().getSimpleName());
        lua.set(entry, "crawling", (boolean)ZombieReads.Filters.CRAWLING.invokeExact(zombie));
        lua.set(entry, "hunting", (Object)ZombieReads.Filters.TARGET.invokeExact(zombie) != null);
        lua.set(entry, "seen", query.seenBy < 0 ? null : (Object)((boolean[])ZombieReads.Handles.VISIBLE.invokeExact(zombie))[query.seenBy]);
    }

    /** A table the call fills again: the entries past the ones just written are taken away. */
    private void trim(Object into, int kept) throws ReflectiveOperationException {
        for (int index = kept + 1; lua.get(into, (double)index) != null; index++) lua.set(into, (double)index, null);
    }

    /**
     * Reads {@code options}: {@code levels} (a list of 1 to 16 whole numbers; the call's {@code z} is then not needed), {@code
     * seenBy} (a player of this machine; each zombie then says whether the game shows it to that player, and {@code seen} true or
     * false keeps only those that are, or are not), {@code targeting} (a character: only the zombies that hunt it), {@code hunting}
     * (true: only those that have a target, false: only those without), {@code crawling} (true or false), {@code state} (the name
     * of one of the game's zombie states, such as {@code "LungeState"}, or a list of them: only the zombies in one of them) and
     * {@code into} (a table to put the list in, with the entries it holds already used again, so that a call each frame makes none).
     * A zombie in the list says, besides the position: its {@code state} (the name of its state's class), {@code crawling},
     * {@code hunting} and, with {@code seenBy}, {@code seen}.
     */
    private Query query(Object options, String call) throws ReflectiveOperationException {
        ZombieReads.Filters.use();
        var query = new Query();
        Object levels = lua.get(options, "levels");
        if (levels != null) {
            if (!lua.isTable(levels)) throw new IllegalArgumentException(call + ": options.levels must be a list of whole numbers");
            int[] found = new int[MAX_LEVELS];
            int count = 0;
            for (Object value = lua.get(levels, 1.0); value != null; value = lua.get(levels, (double)(count + 1))) {
                if (count == MAX_LEVELS) throw new IllegalArgumentException(call + ": options.levels may have at most " + MAX_LEVELS + " levels");
                found[count++] = Arguments.integer(new Object[] { value }, 0, call, "options.levels entry", -MAX_LEVEL, MAX_LEVEL);
            }
            if (count == 0) throw new IllegalArgumentException(call + ": options.levels must name at least one level");
            query.levels = Arrays.copyOf(found, count);
        }
        Object seenBy = lua.get(options, "seenBy");
        if (seenBy != null) {
            Object[] local = players.all();
            for (int index = 0; index < local.length; index++) if (local[index] == seenBy) query.seenBy = index;
            if (query.seenBy < 0) throw new IllegalArgumentException(call + ": options.seenBy must be a player of this machine");
        }
        query.seen = flag(options, "seen", call);
        if (query.seen != null && query.seenBy < 0) throw new IllegalArgumentException(call + ": options.seen needs options.seenBy");
        query.hunting = flag(options, "hunting", call);
        query.crawling = flag(options, "crawling", call);
        Object targeting = lua.get(options, "targeting");
        if (targeting != null) {
            if (lua.isTable(targeting) || targeting instanceof String || targeting instanceof Number || targeting instanceof Boolean)
                throw new IllegalArgumentException(call + ": options.targeting must be a character");
            query.targeting = targeting;
        }
        Object state = lua.get(options, "state");
        if (state != null) {
            var names = new ArrayList<String>();
            if (state instanceof String name) names.add(name);
            else if (lua.isTable(state)) {
                for (Object value = lua.get(state, 1.0); value != null; value = lua.get(state, (double)(names.size() + 1))) {
                    if (!(value instanceof String name)) throw new IllegalArgumentException(call + ": options.state must be a name or a list of names");
                    if (names.size() == MAX_STATES) throw new IllegalArgumentException(call + ": options.state may have at most " + MAX_STATES + " names");
                    names.add(name);
                }
            } else throw new IllegalArgumentException(call + ": options.state must be a name or a list of names");
            if (names.isEmpty()) throw new IllegalArgumentException(call + ": options.state must name at least one state");
            query.inState = new Object[names.size()];
            for (int index = 0; index < query.inState.length; index++) query.inState[index] = state(names.get(index), call);
        }
        Object into = lua.get(options, "into");
        if (into != null) {
            if (!lua.isTable(into)) throw new IllegalArgumentException(call + ": options.into must be a table");
            query.into = into;
        }
        return query;
    }

    private Boolean flag(Object options, String name, String call) throws ReflectiveOperationException {
        Object value = lua.get(options, name);
        if (value != null && !(value instanceof Boolean)) throw new IllegalArgumentException(call + ": options." + name + " must be true or false");
        return (Boolean)value;
    }

    /**
     * The game's State object for a name: the class of that name in {@code zombie.ai.states}, with or without its {@code State}
     * ending, and its {@code instance()}. A name that is none is the mod's error.
     */
    private Object state(String name, String call) throws ReflectiveOperationException {
        Object kept = states.get(name);
        if (kept != null) return kept;
        Object found = null;
        if (STATE_NAME.matcher(name).matches()) {
            for (String candidate : new String[] { name, name + "State" }) {
                try { found = Game.type(loader, STATES + candidate).getMethod("instance").invoke(null); }
                catch (ClassNotFoundException | NoSuchMethodException unknown) { continue; /* the other spelling, or none */ }
                if (found != null) break;
            }
        }
        if (found == null) throw new IllegalArgumentException(call + ": options.state \"" + name + "\" is not one of the game's zombie states (such as \"LungeState\")");
        states.put(name, found);
        return found;
    }

    private static int floor(float value) {
        int whole = (int)value;
        return value < whole ? whole - 1 : whole;
    }
}
