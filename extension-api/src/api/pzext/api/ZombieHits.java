package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Method;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.zombies.watchHits} and the Lua event {@code OnPZExtZombieHit(zombie, attacker, weapon, part, damage, killed)}:
 * a hit a zombie takes, with what the game dealt (docs/design.md, "Zombie hits"), for a mod that reacts to wounds
 * instead of following the zombies.
 *
 * <p>The hook is in {@code IsoZombie.Hit}, after the character's {@code Hit} has worked the damage out, applied it and returned it:
 * so the damage is what was dealt (after the game's reductions, 0 for a hit the game or a mod's {@code WeaponHitCharacter} hook
 * turned away), the zombie is dead or alive as the hit left it, and its {@code lastHitPart} is the part the hit was on. The hook
 * only notes the hit, in a ring of {@link #CAPACITY} places that is written over from its oldest when the frames fall behind; the
 * frame job, on the game's thread, raises at most {@link #MAX_PER_FRAME} events a frame, oldest first. While no mod watches, the
 * game's hook returns after one volatile read (the bootstrap holds no handler), and nothing here runs.
 *
 * <p>Who watches belongs to the world they watched in and is kept in the API table's metatable, where a newer API finds it.
 */
final class ZombieHits implements Hooks.ZombieHits {
    static final String EVENT = "OnPZExtZombieHit";
    static final int CAPACITY = 64, MAX_PER_FRAME = 16;

    private static final String AREA = "PZExtAPI.zombies.";
    // In the API's metatable: the mods that watch (name -> true), and which of the APIs runs the watching now.
    private static final String WATCHERS = "zombieHitWatchers", GENERATION = "zombieHitsGeneration";
    private static final int MASK = CAPACITY - 1;

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    // LuaEventManager.triggerEvent with six arguments.
    private final Method raise;
    // IsoZombie.lastHitPart, Enum.name(), IsoGameCharacter.isDead().
    private final MethodHandle lastHitPart, name, dead;

    private boolean hooked, stopped, watched;

    // The ring the hook writes and the frame job reads, guarded by lock; pending is its count, for the frame to look at without it.
    private final Object lock = new Object();
    private final Object[] zombies = new Object[CAPACITY], attackers = new Object[CAPACITY], weapons = new Object[CAPACITY], parts = new Object[CAPACITY];
    private final float[] damages = new float[CAPACITY];
    private final boolean[] killed = new boolean[CAPACITY];
    private long head, tail, overwritten;
    private volatile int pending;

    // The game's cell when the frame last looked: a world left takes the watching with it.
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    // This environment's watching as GENERATION numbers it; 0 until register.
    private long generation;

    ZombieHits(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        ZombieReads.use(loader);
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        raise = Game.type(loader, "zombie.Lua.LuaEventManager").getMethod("triggerEvent", String.class, Object.class, Object.class,
            Object.class, Object.class, Object.class, Object.class);
        Class<?> zombie = Game.type(loader, "zombie.characters.IsoZombie");
        lastHitPart = MethodHandles.publicLookup().unreflectGetter(zombie.getField("lastHitPart")).asType(MethodType.methodType(Object.class, Object.class));
        name = MethodHandles.publicLookup().unreflect(Enum.class.getMethod("name")).asType(MethodType.methodType(String.class, Object.class));
        dead = ZombieReads.Handles.DEAD;
    }

    /** Takes the game's hook while a mod watches. Throws a LinkageError with a bootstrap from before the zombie hits. */
    void hook() throws ReflectiveOperationException {
        hooked = true;
        update();
    }

    /** Nobody watches the hits: the hook returns at once. */
    static void unhook() {
        try { Hooks.setZombieHits(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No watching runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    /** Sets {@code watchHits} into the zombies' table, replacing an earlier API's, and makes the event known to the game. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        game.addEvent(EVENT);
        String call = AREA + "watchHits";
        lua.set(table, "watchHits", lua.function(call, arguments -> {
            current(call);
            String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
            if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
            Object on = arguments.length > 1 ? arguments[1] : null;
            if (on != null && !(on instanceof Boolean)) throw new IllegalArgumentException(call + ": on must be true or false");
            lua.set(watchers(), owner, Boolean.TRUE.equals(on) ? (Object)true : null);
            update();
            return new Object[] { watched };
        }));
    }

    /** Refuses a call into watching that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** {@code handle:clear()}: the mod no longer watches. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        Object watching = lua.get(meta, WATCHERS);
        if (watching == null || lua.get(watching, owner) == null) return;
        lua.set(watching, owner, null);
        update();
    }

    private Object watchers() throws ReflectiveOperationException {
        Object table = lua.get(meta, WATCHERS);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(meta, WATCHERS, table); }
        return table;
    }

    /** The game's hook is taken while any mod watches. */
    private void update() throws ReflectiveOperationException {
        if (stopped) return;
        boolean any = false;
        Object watching = lua.get(meta, WATCHERS);
        if (lua.isTable(watching)) for (var entry : lua.entries(watching)) if (entry.getValue() != null) any = true;
        watched = any;
        if (!any) forget();
        if (hooked) Hooks.setZombieHits(any ? this : null);
    }

    /** What is noted: nobody watches any more. */
    private void forget() {
        synchronized (lock) {
            java.util.Arrays.fill(zombies, null);
            java.util.Arrays.fill(attackers, null);
            java.util.Arrays.fill(weapons, null);
            java.util.Arrays.fill(parts, null);
            tail = head;
            pending = 0;
        }
    }

    /** Whether any mod watches, for the tests. */
    boolean watched() { return watched; }

    /** How many noted hits were written over before the frame job raised them (for the tests). */
    long overwritten() { synchronized (lock) { return overwritten; } }

    /** How many hits are noted and not yet raised (for the tests). */
    int pending() { return pending; }

    // ---- the hook: on the thread that makes the hit; nothing allocated ----

    @Override public void hit(Object zombie, Object attacker, Object weapon, float damage) {
        if (zombie == null) return;
        Object part;
        boolean isDead;
        try {
            part = (Object)lastHitPart.invokeExact(zombie);
            isDead = (boolean)dead.invokeExact(zombie);
        } catch (Throwable failure) { throw ZombieHits.<RuntimeException>sneaky(failure); }
        synchronized (lock) {
            int at = (int)(head & MASK);
            zombies[at] = zombie;
            attackers[at] = attacker;
            weapons[at] = weapon;
            parts[at] = part;
            damages[at] = damage;
            killed[at] = isDead;
            // Full: the place written was the oldest's.
            if (++head - tail > CAPACITY) { tail = head - CAPACITY; overwritten++; }
            pending = (int)(head - tail);
        }
    }

    // ---- the frame job: on the game's thread ----

    /** Raises the events noted since the last frame (at most {@link #MAX_PER_FRAME}); a world left takes the watching with it. */
    void frame() throws Throwable {
        if (moves.moved()) {
            Object cell = game.cell();
            if (world != null && cell != world) leave();
            world = cell;
        }
        if (pending == 0) return;
        for (int raised = 0; raised < MAX_PER_FRAME; raised++) {
            Object zombie, attacker, weapon, part;
            float damage;
            boolean wasKilled;
            synchronized (lock) {
                if (head == tail) break;
                int at = (int)(tail & MASK);
                zombie = zombies[at]; attacker = attackers[at]; weapon = weapons[at]; part = parts[at];
                damage = damages[at];
                wasKilled = killed[at];
                zombies[at] = attackers[at] = weapons[at] = parts[at] = null;
                tail++;
                pending = (int)(head - tail);
            }
            raise.invoke(null, EVENT, zombie, attacker, weapon, part == null ? null : (String)name.invokeExact(part), (double)damage, wasKilled);
        }
    }

    /** The world the mods watched in was left: they watch again in the next one. */
    private void leave() throws ReflectiveOperationException {
        Object watching = lua.get(meta, WATCHERS);
        if (lua.isTable(watching)) lua.set(meta, WATCHERS, null);
        update();
    }

    /**
     * A fault in the frame job: the hook is given back and nothing more is noted or raised, whatever the mods ask (their
     * {@code watchHits} then answers false). Once; the rest of the API goes on.
     */
    void stop() {
        stopped = true;
        watched = false;
        unhook();
        forget();
    }

    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E sneaky(Throwable failure) throws E { throw (E)failure; }
}
