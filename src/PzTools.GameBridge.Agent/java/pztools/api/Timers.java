package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.function.DoubleSupplier;
import java.util.function.LongSupplier;

/**
 * {@code PZToolsAPI.timers}: Lua functions called every so many milliseconds, or so many minutes of the game's time, from the frame job
 * on the game's thread (docs/design/extension-api.md, "Timers"), instead of a handler on every tick that counts them itself.
 *
 * <p>A frame with no timer due costs one clock read and a comparison with the soonest due (and a read of the world's age, once
 * a frame, only while a timer counts game minutes); with none at all, a check of an empty list. A timer that falls behind (a long
 * frame, a game sped up, a pause) is called once for all the periods it missed and told how many they were: nothing is called in
 * a burst. A timer counts real time (the clock the interface runs on, which goes on while the game is paused) or the game's time
 * (the world's age, which does not).
 *
 * <p>The timers belong to the world they were made in: leaving it takes them away. They are kept in the API table's metatable,
 * where a newer API takes them over at the moment they were at.
 */
final class Timers {
    static final int MAX_PER_MOD = 64, MAX_ALL = 256;
    static final double MIN_MS = 1, MAX_MS = 86_400_000, MIN_MINUTES = 0.01, MAX_MINUTES = 1440;

    private static final String AREA = "PZToolsAPI.timers.";
    // In the API's metatable: the timers (id -> record), the number of the next, and which API runs them now.
    private static final String KEPT = "timers", NEXT = "timersNext", GENERATION = "timersGeneration";
    private static final double NANOS_PER_MS = 1_000_000;

    /** The clocks, in nanoseconds and in minutes of the world's age; the tests set them. */
    LongSupplier clock = System::nanoTime;
    DoubleSupplier minutesClock;

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    // GameTime.getInstance() and GameTime.getWorldAgeHours().
    private final MethodHandle time, age;

    /** One timer: when it is next due, in the unit it counts. */
    private static final class Timer {
        final long id;
        final String owner;
        final boolean minutes, once;
        // Nanoseconds, or minutes.
        final double interval;
        double due;
        final Object function, record, cell;
        boolean cancelled, reported;

        Timer(long id, String owner, boolean minutes, boolean once, double interval, double due, Object function, Object record, Object cell) {
            this.id = id; this.owner = owner; this.minutes = minutes; this.once = once; this.interval = interval; this.due = due;
            this.function = function; this.record = record; this.cell = cell;
        }
    }

    private final ArrayList<Timer> timers = new ArrayList<>();
    private int minuteTimers;
    // The soonest due of each unit; read by every frame.
    private double nextNanos = Double.POSITIVE_INFINITY, nextMinutes = Double.POSITIVE_INFINITY;
    private long next = 1;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private long generation;
    // How many callbacks were called, for the tests.
    private long calls;

    Timers(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        Class<?> gameTime = Game.type(loader, "zombie.GameTime");
        time = Game.exact(gameTime.getMethod("getInstance"), MethodType.methodType(Object.class));
        age = Game.exact(gameTime.getMethod("getWorldAgeHours"), MethodType.methodType(double.class, Object.class));
        minutesClock = this::ageMinutes;
        world = game.cell();
        load();
    }

    /** No timer runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    private double ageMinutes() {
        try { return (double)age.invokeExact((Object)time.invokeExact()) * 60; }
        catch (Throwable failure) { throw Timers.<RuntimeException>sneaky(failure); }
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            return body.call(call, arguments);
        }));
    }

    /** Refuses a call into timers that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZToolsAPI");
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        function(table, "every", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object spec = arguments.length > 1 ? arguments[1] : null;
            if (!lua.isTable(spec)) throw new IllegalArgumentException(call + ": spec must be a table, such as { ms = 500 } or { minutes = 10 }");
            Object function = arguments.length > 2 ? arguments[2] : null;
            if (function == null || function instanceof String || function instanceof Number || function instanceof Boolean || lua.isTable(function))
                throw new IllegalArgumentException(call + ": the third argument must be a function");
            Object ms = lua.get(spec, "ms"), minutes = lua.get(spec, "minutes"), once = lua.get(spec, "once");
            if ((ms == null) == (minutes == null)) throw new IllegalArgumentException(call + ": spec must have ms or minutes, one of them");
            if (once != null && !(once instanceof Boolean)) throw new IllegalArgumentException(call + ": spec.once must be true or false");
            boolean inMinutes = minutes != null;
            double interval = inMinutes ? number(minutes, call, "spec.minutes", MIN_MINUTES, MAX_MINUTES) : number(ms, call, "spec.ms", MIN_MS, MAX_MS);
            int own = 0;
            for (Timer timer : timers) if (timer.owner.equals(owner)) own++;
            if (own >= MAX_PER_MOD) throw new IllegalArgumentException(call + ": the mod has " + own + " timers; at most " + MAX_PER_MOD);
            if (timers.size() >= MAX_ALL) throw new IllegalArgumentException(call + ": the mods have " + timers.size() + " timers; at most " + MAX_ALL);
            Object cell = game.cell();
            double step = inMinutes ? interval : interval * NANOS_PER_MS;
            double due = (inMinutes ? minutesClock.getAsDouble() : clock.getAsLong()) + step;
            Object record = lua.table();
            long id = next++;
            Timer timer = new Timer(id, owner, inMinutes, Boolean.TRUE.equals(once), step, due, function, record, cell);
            write(timer);
            timers.add(timer);
            lua.set(meta, NEXT, (double)next);
            lua.set(kept(), (double)id, record);
            changed();
            return new Object[] { (double)id };
        });
        function(table, "cancel", (call, arguments) -> {
            String owner = owner(arguments, call);
            Object value = arguments.length > 1 ? arguments[1] : null;
            if (!(value instanceof Double number) || number != Math.rint(number) || number < 1)
                throw new IllegalArgumentException(call + ": id must be what every returned");
            for (Timer timer : timers)
                if (timer.id == number.longValue() && timer.owner.equals(owner)) { remove(timer); return new Object[] { true }; }
            return new Object[] { false };
        });
    }

    /** The table the records are kept in (by id), made as it is first needed. */
    private Object kept() throws ReflectiveOperationException {
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(meta, KEPT, table); }
        return table;
    }

    private static double number(Object value, String call, String name, double min, double max) {
        if (!(value instanceof Double number) || !(number >= min && number <= max))
            throw new IllegalArgumentException(call + ": " + name + " must be a number from " + trim(min) + " to " + trim(max));
        return number;
    }

    private static String trim(double value) { return value == Math.rint(value) ? Long.toString((long)value) : Double.toString(value); }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
        return owner;
    }

    /** {@code handle:clear()}: the mod's timers stop. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        for (Timer timer : new ArrayList<>(timers)) if (timer.owner.equals(owner)) remove(timer);
    }

    private void remove(Timer timer) throws ReflectiveOperationException {
        timer.cancelled = true;
        if (timers.remove(timer)) lua.set(kept(), (double)timer.id, null);
        changed();
    }

    /** Works out again what the frame compares with, after a timer came or went. */
    private void changed() {
        minuteTimers = 0;
        nextNanos = Double.POSITIVE_INFINITY;
        nextMinutes = Double.POSITIVE_INFINITY;
        for (Timer timer : timers) {
            if (timer.minutes) { minuteTimers++; nextMinutes = Math.min(nextMinutes, timer.due); }
            else nextNanos = Math.min(nextNanos, timer.due);
        }
    }

    // ---- kept for a newer API ----

    private void write(Timer timer) throws ReflectiveOperationException {
        Object record = timer.record;
        lua.set(record, "owner", timer.owner);
        lua.set(record, "minutes", timer.minutes);
        lua.set(record, "once", timer.once);
        lua.set(record, "interval", timer.interval);
        lua.set(record, "due", timer.due);
        lua.set(record, "function", timer.function);
        lua.set(record, "cell", timer.cell);
    }

    /** What an earlier API ran, from where it was (the same process's clock): in this world. */
    private void load() throws ReflectiveOperationException {
        Object before = lua.get(meta, NEXT);
        if (before instanceof Double number) next = Math.max(next, number.longValue());
        Object table = lua.get(meta, KEPT);
        if (!lua.isTable(table)) return;
        for (var entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof Double key) || !lua.isTable(entry.getValue())) continue;
            Object record = entry.getValue();
            if (!(lua.get(record, "owner") instanceof String owner) || !(lua.get(record, "interval") instanceof Double interval)
                    || !(lua.get(record, "due") instanceof Double due) || lua.get(record, "function") == null) continue;
            Object cell = lua.get(record, "cell");
            if (cell != world) { lua.set(table, key, null); continue; }
            timers.add(new Timer(key.longValue(), owner, Boolean.TRUE.equals(lua.get(record, "minutes")), Boolean.TRUE.equals(lua.get(record, "once")),
                interval, due, lua.get(record, "function"), record, cell));
            next = Math.max(next, key.longValue() + 1);
        }
        timers.sort((first, second) -> Long.compare(first.id, second.id));
        changed();
    }

    // ---- the frame job: on the game's thread ----

    /** Calls the functions of the timers that are due; a world left takes its timers away. */
    void frame() {
        if (timers.isEmpty()) return;
        try {
            if (moves.moved()) {
                Object cell = game.cell();
                if (cell != world) {
                    world = cell;
                    for (Timer timer : new ArrayList<>(timers)) if (timer.cell != cell) remove(timer);
                    if (timers.isEmpty()) return;
                }
            }
            long now = clock.getAsLong();
            double minutes = minuteTimers > 0 ? minutesClock.getAsDouble() : 0;
            if (now < nextNanos && (minuteTimers == 0 || minutes < nextMinutes)) return;
            for (Timer timer : new ArrayList<>(timers)) {
                if (timer.cancelled) continue;
                double at = timer.minutes ? minutes : now;
                if (at < timer.due) continue;
                long periods = (long)Math.floor((at - timer.due) / timer.interval) + 1;
                timer.due += periods * timer.interval;
                if (timer.once) remove(timer);
                else { lua.set(timer.record, "due", timer.due); }
                call(timer, periods);
            }
            changed();
        } catch (Throwable failure) {
            // A fault in the frame job's own work (not a timer's function: that is caught in call): once is enough.
            if (!reported) System.err.println("[PzTools API] timers: " + failure);
            reported = true;
        }
    }

    private boolean reported;

    private void call(Timer timer, long periods) {
        calls++;
        try {
            Object[] results = lua.call(timer.function, (double)timer.id, (double)periods);
            if (results.length > 0 && !Boolean.TRUE.equals(results[0]) && !timer.reported) {
                timer.reported = true;
                System.err.println("[PzTools API] timers: the function of timer " + timer.id + " (" + timer.owner + ") failed: "
                    + (results.length > 1 ? results[1] : "unknown"));
            }
        } catch (ReflectiveOperationException | RuntimeException failure) {
            if (!timer.reported) System.err.println("[PzTools API] timers: the function of timer " + timer.id + " (" + timer.owner + ") could not be called: " + failure);
            timer.reported = true;
        }
    }

    /** How many timers run, and how many callbacks were called (for the tests). */
    int count() { return timers.size(); }

    long calls() { return calls; }

    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E sneaky(Throwable failure) throws E { throw (E)failure; }
}
