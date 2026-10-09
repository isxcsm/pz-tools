package pztools.api;

import java.lang.reflect.Method;
import java.util.function.LongSupplier;
import pztools.bridge.ApiHooks;

/**
 * {@code PZToolsAPI.zombies.listen} and the Lua event {@code OnPZToolsZombieSound(kind, x, y, z, loudness, zombie)}: the sounds
 * zombies make that the game hands to FMOD alone (docs/design/extension-api.md, "Zombie sounds"), for a mod that shows where
 * a zombie was heard instead of following the zombies.
 *
 * <p>The hooks note a moment where it happens, on the thread that updates the zombies: the kind, and where the zombie was, in a
 * ring of {@link #CAPACITY} places that is written over from its oldest when the frame job falls behind. A moment no local player
 * is within the listened radius of (in squares, across the ground; the floor is the mod's to judge) is not noted. The frame job,
 * on the game's thread, raises at most {@link #MAX_PER_FRAME} events a frame, oldest first, and leaves out the same kind from the
 * same zombie within {@link #REPEAT_NANOS} of the last one raised. While no mod listens the game's hooks return after one
 * volatile read (the bootstrap holds no handler), and nothing here runs.
 *
 * <p>What a mod listens with belongs to the world it listened in and is kept in the API table's metatable, where a newer API finds
 * it; the event is raised to every handler, with the largest radius any mod asked for.
 */
final class ZombieSounds implements ApiHooks.ZombieSounds {
    static final String EVENT = "OnPZToolsZombieSound";
    static final double MAX_RADIUS = 1000;
    static final int CAPACITY = 64, MAX_PER_FRAME = 8;
    /** The same kind from the same zombie within this long of the last one raised is not raised again. */
    static final long REPEAT_NANOS = 1_000_000_000L;
    /** The clock, in nanoseconds; the tests set it. */
    static volatile LongSupplier clock = System::nanoTime;

    /** The kinds, as the event names them. */
    static final int VOICE = 0, AGGRO = 1, LUNGE = 2, ATTACK = 3, HIT = 4, DEATH = 5, FALL = 6;
    static final String[] KINDS = { "voice", "aggro", "lunge", "attack", "hit", "death", "fall" };
    /**
     * How loud each kind is, in squares: the radius the game gives the zombie's sound where it has one
     * ({@code IsoZombie$ZombieSound}, what a server tells its clients to play: Idle for the voice and the aggro, Lunge, Hurt for a
     * hit and a fall, DeadCloseKilled); these when the game has none, or another shape of it.
     */
    static final double[] DEFAULT_LOUDNESS = { 15, 15, 40, 15, 10, 10, 10 };

    private static final String AREA = "PZToolsAPI.zombies.";
    // In the API's metatable: the mods that listen (name -> radius), and which of the APIs runs the listening now.
    private static final String LISTENERS = "zombieListeners", GENERATION = "zombieSoundsGeneration";
    private static final int MASK = CAPACITY - 1, RECENT = 32;

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final Players players;
    // LuaEventManager.triggerEvent with six arguments.
    private final Method raise;
    // The kind of each ParameterZombieState$State by its ordinal (-1: no sound of its own), and the states a zombie is
    // aggravated from.
    private final byte[] kindOf;
    private final boolean[] calm;
    private final Double[] loudness = new Double[KINDS.length];

    // The largest radius listened with, squared; 0 while nobody listens. Written on the game's thread, read by the hooks.
    private volatile double reach;
    private boolean hooked, stopped;

    // The ring the hooks write and the frame job reads, guarded by lock; pending is its count, for the frame to look at without it.
    private final Object lock = new Object();
    private final Object[] zombies = new Object[CAPACITY];
    private final byte[] kinds = new byte[CAPACITY];
    private final float[] xs = new float[CAPACITY], ys = new float[CAPACITY], zs = new float[CAPACITY];
    private long head, tail, overwritten;
    private volatile int pending;

    // The frame job's: the last events raised, to leave out a repeat (the oldest place is taken by the next).
    private final Object[] recentZombie = new Object[RECENT];
    private final byte[] recentKind = new byte[RECENT];
    private final long[] recentAt = new long[RECENT];
    private final boolean[] recentUsed = new boolean[RECENT];
    private long repeats;

    // The game's cell when the frame last looked: a world left takes the listening with it.
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    // This environment's listening as GENERATION numbers it; 0 until register.
    private long generation;

    ZombieSounds(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        ZombieReads.use(loader);
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        players = new Players(loader);
        raise = Game.type(loader, "zombie.Lua.LuaEventManager").getMethod("triggerEvent", String.class, Object.class, Object.class,
            Object.class, Object.class, Object.class, Object.class);
        Class<?> state = Game.type(loader, "zombie.audio.parameters.ParameterZombieState$State");
        Object[] states = state.getEnumConstants();
        if (states == null) throw new NoSuchFieldException("ParameterZombieState$State is not an enum");
        kindOf = new byte[states.length];
        calm = new boolean[states.length];
        for (Object value : states) {
            Enum<?> constant = (Enum<?>)value;
            kindOf[constant.ordinal()] = (byte)switch (constant.name()) {
                case "SearchTarget" -> AGGRO;
                case "LockTarget" -> LUNGE;
                case "Attack", "AttackScratch", "AttackLacerate", "AttackBite" -> ATTACK;
                case "Hit", "Pushed", "RunOver" -> HIT;
                case "Death" -> DEATH;
                default -> -1;
            };
            calm[constant.ordinal()] = switch (constant.name()) {
                case "Idle", "Eating", "GettingUp", "Reanimate" -> true;
                default -> false;
            };
        }
        double[] loud = DEFAULT_LOUDNESS.clone();
        try {
            Class<?> sound = Game.type(loader, "zombie.characters.IsoZombie$ZombieSound");
            Method radius = sound.getMethod("radius");
            loud[VOICE] = loud[AGGRO] = (int)radius.invoke(sound.getField("Idle").get(null));
            loud[LUNGE] = (int)radius.invoke(sound.getField("Lunge").get(null));
            loud[HIT] = loud[FALL] = (int)radius.invoke(sound.getField("Hurt").get(null));
            loud[DEATH] = (int)radius.invoke(sound.getField("DeadCloseKilled").get(null));
        } catch (ReflectiveOperationException | RuntimeException | LinkageError other) {
            System.err.println("[PzTools API] zombie sounds: the game's sound radii could not be read, the API's are used: " + other);
            loud = DEFAULT_LOUDNESS.clone();
        }
        for (int kind = 0; kind < loud.length; kind++) loudness[kind] = loud[kind];
    }

    /** Takes the game's hooks while a mod listens. Throws a LinkageError with a bootstrap from before the zombie sounds. */
    void hook() throws ReflectiveOperationException {
        hooked = true;
        update();
    }

    /** Nobody hears the zombies' sounds: the hooks return at once. */
    static void unhook() {
        try { ApiHooks.setZombieSounds(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No listening runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    /** Sets {@code listen} into the zombies' table, replacing an earlier API's, and makes the event known to the game. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        game.addEvent(EVENT);
        String call = AREA + "listen";
        lua.set(table, "listen", lua.function(call, arguments -> {
            current(call);
            String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
            if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZToolsAPI.client");
            double radius = arguments.length > 1 && arguments[1] != null ? Arguments.number(arguments, 1, call, "radius", 0, MAX_RADIUS) : 0;
            lua.set(listeners(), owner, radius > 0 ? (Object)radius : null);
            update();
            return new Object[] { Math.sqrt(reach) };
        }));
    }

    /** Refuses a call into listening that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZToolsAPI");
    }

    /** {@code handle:clear()}: the mod no longer listens. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        Object listening = lua.get(meta, LISTENERS);
        if (listening == null || lua.get(listening, owner) == null) return;
        lua.set(listening, owner, null);
        update();
    }

    private Object listeners() throws ReflectiveOperationException {
        Object table = lua.get(meta, LISTENERS);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(meta, LISTENERS, table); }
        return table;
    }

    /** The largest radius any mod listens with, as the hooks read it; the game's hooks are taken while there is one. */
    private void update() throws ReflectiveOperationException {
        if (stopped) return;
        double largest = 0;
        Object listening = lua.get(meta, LISTENERS);
        if (lua.isTable(listening))
            for (var entry : lua.entries(listening)) if (entry.getValue() instanceof Double radius && radius > largest) largest = radius;
        reach = largest * largest;
        if (largest == 0) forget();
        if (hooked) ApiHooks.setZombieSounds(largest > 0 ? this : null);
    }

    /** What is noted and what was raised: nobody hears it any more. */
    private void forget() {
        synchronized (lock) {
            java.util.Arrays.fill(zombies, null);
            tail = head;
            pending = 0;
        }
        java.util.Arrays.fill(recentZombie, null);
        java.util.Arrays.fill(recentUsed, false);
    }

    /** The radius in effect (the largest any mod listens with), for the tests. */
    double radius() { return Math.sqrt(reach); }

    /** How many noted moments were written over before the frame job raised them, and how many repeats it left out (for the tests). */
    long overwritten() { synchronized (lock) { return overwritten; } }

    long repeats() { return repeats; }

    /** How many moments are noted and not yet raised (for the tests). */
    int pending() { return pending; }

    // ---- the hooks: on the thread that updates the zombies; nothing allocated ----

    @Override public void state(Object zombie, Object from, Object to) {
        if (!(to instanceof Enum<?> next)) return;
        int ordinal = next.ordinal();
        if (ordinal >= kindOf.length) return;
        int kind = kindOf[ordinal];
        if (kind < 0) return;
        // Aggravated: from a calm state (the game goes to SearchTarget from Idle alone, when the zombie has a target).
        if (kind == AGGRO && from instanceof Enum<?> previous && previous.ordinal() < calm.length && !calm[previous.ordinal()]) return;
        note(zombie, kind);
    }

    @Override public void voice(Object zombie) { note(zombie, VOICE); }

    @Override public void landed(Object zombie) { note(zombie, FALL); }

    private void note(Object zombie, int kind) {
        double within = reach;
        if (within <= 0 || zombie == null) return;
        float x, y, z;
        try {
            x = (float)ZombieReads.Handles.X.invokeExact(zombie);
            y = (float)ZombieReads.Handles.Y.invokeExact(zombie);
            if (!heard(x, y, within)) return;
            z = (float)ZombieReads.Handles.Z.invokeExact(zombie);
        } catch (Throwable failure) { throw ZombieSounds.<RuntimeException>sneaky(failure); }
        synchronized (lock) {
            int at = (int)(head & MASK);
            zombies[at] = zombie;
            kinds[at] = (byte)kind;
            xs[at] = x;
            ys[at] = y;
            zs[at] = z;
            // Full: the place written was the oldest's.
            if (++head - tail > CAPACITY) { tail = head - CAPACITY; overwritten++; }
            pending = (int)(head - tail);
        }
    }

    /** Whether a local player is within the radius of the point, across the ground. */
    private boolean heard(float x, float y, double within) throws Throwable {
        for (Object player : players.all()) {
            if (player == null) continue;
            double dx = (float)ZombieReads.Handles.X.invokeExact(player) - x, dy = (float)ZombieReads.Handles.Y.invokeExact(player) - y;
            if (dx * dx + dy * dy <= within) return true;
        }
        return false;
    }

    // ---- the frame job: on the game's thread ----

    /** Raises the events noted since the last frame (at most {@link #MAX_PER_FRAME}); a world left takes the listening with it. */
    void frame() throws ReflectiveOperationException {
        if (moves.moved()) {
            Object cell = game.cell();
            if (world != null && cell != world) leave();
            world = cell;
        }
        if (pending == 0) return;
        long now = clock.getAsLong();
        for (int raised = 0; raised < MAX_PER_FRAME;) {
            Object zombie;
            int kind;
            float x, y, z;
            synchronized (lock) {
                if (head == tail) break;
                int at = (int)(tail & MASK);
                zombie = zombies[at];
                zombies[at] = null;
                kind = kinds[at];
                x = xs[at];
                y = ys[at];
                z = zs[at];
                tail++;
                pending = (int)(head - tail);
            }
            if (repeated(zombie, kind, now)) { repeats++; continue; }
            raise.invoke(null, EVENT, KINDS[kind], (double)x, (double)y, (double)z, loudness[kind], zombie);
            raised++;
        }
    }

    /** Whether the same kind from the same zombie was raised within {@link #REPEAT_NANOS}; if not, it is remembered as raised now. */
    private boolean repeated(Object zombie, int kind, long now) {
        int oldest = 0;
        for (int index = 0; index < RECENT; index++) {
            if (!recentUsed[index]) { oldest = index; continue; }
            if (recentZombie[index] == zombie && recentKind[index] == kind && now - recentAt[index] < REPEAT_NANOS) return true;
            if (recentUsed[oldest] && recentAt[index] - recentAt[oldest] < 0) oldest = index;
        }
        recentUsed[oldest] = true;
        recentZombie[oldest] = zombie;
        recentKind[oldest] = (byte)kind;
        recentAt[oldest] = now;
        return false;
    }

    /** The world the mods listened in was left: they listen again in the next one. */
    private void leave() throws ReflectiveOperationException {
        Object listening = lua.get(meta, LISTENERS);
        if (lua.isTable(listening)) lua.set(meta, LISTENERS, null);
        update();
    }

    /**
     * A fault in the frame job: the hooks are given back and nothing more is noted or raised, whatever the mods ask (their
     * {@code listen} then answers a radius of 0). Once; the rest of the API goes on.
     */
    void stop() {
        stopped = true;
        reach = 0;
        unhook();
        forget();
    }

    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E sneaky(Throwable failure) throws E { throw (E)failure; }
}
