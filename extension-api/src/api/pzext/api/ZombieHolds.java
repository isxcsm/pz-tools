package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.zombies.hold} and {@code release}: zombies of an outfit kept in an area (docs/design.md, "Zombie holds"), for a
 * mod that puts a group somewhere and wants it found there: an idle one wanders within the circle, one heard only the sounds of
 * players and of the area while it is near, and, when the mod asks, one of the outfit goes as its chunk unloads instead of staying
 * as a virtual zombie the game moves about unseen.
 *
 * <p>The holds are read by three hooks, on the game's thread: where {@code ZombieIdleState} sends an idle zombie (a target outside
 * the circle is brought in along the line to its centre), each sound {@code WorldSoundManager.getBiggestSoundZomb} weighs (one the
 * zombie must not hear is skipped, as the game skips a missing one), and each zombie {@code ZombiePopulationManager.removeChunkFromWorld}
 * would keep virtual (one that goes is released from the population instead). A zombie is held while it is within the circle and
 * its margin; one that chased a player further is the game's until it comes back. The hooks find the holds by the zombie's outfit
 * name, in a map made again when the holds change; with none, the game's hooks return after one volatile read.
 *
 * <p>The holds belong to the world they were made in, and are kept in the API table's metatable, where a newer API takes them over.
 */
final class ZombieHolds implements Hooks.ZombieHolds {
    static final int MAX_PER_MOD = 64, MAX_RADIUS = 300, MAX_MARGIN = 300, DEFAULT_MARGIN = 20;

    private static final String AREA = "PZExtAPI.zombies.";
    // In the API's metatable: the holds (owner -> id -> { outfit, x, y, radius, margin, dissolve }), and which API runs them.
    private static final String KEPT = "zombieHolds", GENERATION = "zombieHoldsGeneration";

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final MethodHandle outfit, zombieX, zombieY, soundX, soundY, soundPlayer;

    /** One hold as the hooks read it. */
    record Hold(float x, float y, float radius, float reach, boolean dissolve) {
        boolean near(float px, float py) {
            float dx = px - x, dy = py - y;
            return dx * dx + dy * dy <= reach * reach;
        }
    }

    // The holds by outfit name; empty while none.
    private volatile Map<String, Hold[]> holds = Map.of();
    private boolean hooked, stopped;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private long generation;

    ZombieHolds(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        var lookup = MethodHandles.publicLookup();
        Class<?> zombie = Game.type(loader, "zombie.characters.IsoZombie"), sound = Game.type(loader, "zombie.WorldSoundManager$WorldSound");
        outfit = Game.exact(zombie.getMethod("getOutfitName"), MethodType.methodType(String.class, Object.class));
        zombieX = Game.exact(zombie.getMethod("getX"), MethodType.methodType(float.class, Object.class));
        zombieY = Game.exact(zombie.getMethod("getY"), MethodType.methodType(float.class, Object.class));
        soundX = lookup.unreflectGetter(sound.getField("x")).asType(MethodType.methodType(int.class, Object.class));
        soundY = lookup.unreflectGetter(sound.getField("y")).asType(MethodType.methodType(int.class, Object.class));
        soundPlayer = lookup.unreflectGetter(sound.getField("sourceIsPlayer")).asType(MethodType.methodType(boolean.class, Object.class));
        world = game.cell();
    }

    /** Takes the game's hooks while a zombie is held. Throws a LinkageError with a bootstrap from before the holds. */
    void hook() throws ReflectiveOperationException {
        hooked = true;
        update();
    }

    /** No zombie is held: the hooks answer as the game. */
    static void unhook() {
        try { Hooks.setZombieHolds(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No holding runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    /** Sets {@code hold} and {@code release} into the zombies' table, replacing an earlier API's. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        String holdCall = AREA + "hold", releaseCall = AREA + "release";
        lua.set(table, "hold", lua.function(holdCall, arguments -> {
            current(holdCall);
            String owner = owner(arguments, holdCall);
            String id = Arguments.name(arguments, 1, holdCall, "id");
            Object spec = arguments.length > 2 ? arguments[2] : null;
            if (!lua.isTable(spec)) throw new IllegalArgumentException(holdCall + ": the hold must be a table");
            Object outfitName = lua.get(spec, "outfit");
            if (!(outfitName instanceof String text) || text.isEmpty() || text.length() > 64)
                throw new IllegalArgumentException(holdCall + ": outfit must be an outfit's name");
            double x = number(lua.get(spec, "x"), holdCall, "x", -SquareWatches.MAX_COORDINATE, SquareWatches.MAX_COORDINATE);
            double y = number(lua.get(spec, "y"), holdCall, "y", -SquareWatches.MAX_COORDINATE, SquareWatches.MAX_COORDINATE);
            double radius = number(lua.get(spec, "radius"), holdCall, "radius", 1, MAX_RADIUS);
            Object marginValue = lua.get(spec, "margin");
            double margin = marginValue == null ? DEFAULT_MARGIN : number(marginValue, holdCall, "margin", 0, MAX_MARGIN);
            Object dissolve = lua.get(spec, "dissolve");
            if (dissolve != null && !(dissolve instanceof Boolean)) throw new IllegalArgumentException(holdCall + ": dissolve must be true or false");
            Object mine = mine(owner, true);
            if (lua.get(mine, id) == null && count(mine) >= MAX_PER_MOD)
                throw new IllegalArgumentException(holdCall + ": a mod holds " + MAX_PER_MOD + " areas at most");
            Object kept = lua.table();
            lua.set(kept, "outfit", outfitName);
            lua.set(kept, "x", x); lua.set(kept, "y", y); lua.set(kept, "radius", radius); lua.set(kept, "margin", margin);
            lua.set(kept, "dissolve", Boolean.TRUE.equals(dissolve));
            lua.set(mine, id, kept);
            update();
            return new Object[0];
        }));
        lua.set(table, "release", lua.function(releaseCall, arguments -> {
            current(releaseCall);
            String owner = owner(arguments, releaseCall);
            String id = Arguments.name(arguments, 1, releaseCall, "id");
            Object mine = mine(owner, false);
            if (mine != null && lua.get(mine, id) != null) {
                lua.set(mine, id, null);
                update();
            }
            return new Object[0];
        }));
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
        return owner;
    }

    private static double number(Object value, String call, String name, double min, double max) {
        if (!(value instanceof Number number) || !(number.doubleValue() >= min && number.doubleValue() <= max))
            throw new IllegalArgumentException(call + ": " + name + " must be a number from " + (long)min + " to " + (long)max);
        return number.doubleValue();
    }

    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** The mod's holds (id -> hold), made when {@code make}; else null when it has none. */
    private Object mine(String owner, boolean make) throws ReflectiveOperationException {
        Object all = lua.get(meta, KEPT);
        if (!lua.isTable(all)) {
            if (!make) return null;
            all = lua.table();
            lua.set(meta, KEPT, all);
        }
        Object mine = lua.get(all, owner);
        if (!lua.isTable(mine)) {
            if (!make) return null;
            mine = lua.table();
            lua.set(all, owner, mine);
        }
        return mine;
    }

    private int count(Object table) throws ReflectiveOperationException {
        int count = 0;
        for (var entry : lua.entries(table)) if (entry.getValue() != null) count++;
        return count;
    }

    /** {@code handle:clear()}: the mod holds nothing. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        Object all = lua.get(meta, KEPT);
        if (!lua.isTable(all) || lua.get(all, owner) == null) return;
        lua.set(all, owner, null);
        update();
    }

    /** The holds as the hooks read them, made again from the kept ones; the hooks are taken while any is. */
    private void update() throws ReflectiveOperationException {
        if (stopped) return;
        var byOutfit = new HashMap<String, ArrayList<Hold>>();
        Object all = lua.get(meta, KEPT);
        if (lua.isTable(all))
            for (var owner : lua.entries(all)) {
                if (!lua.isTable(owner.getValue())) continue;
                for (var entry : lua.entries(owner.getValue())) {
                    Object kept = entry.getValue();
                    if (!lua.isTable(kept)) continue;
                    float radius = ((Double)lua.get(kept, "radius")).floatValue(), margin = ((Double)lua.get(kept, "margin")).floatValue();
                    byOutfit.computeIfAbsent((String)lua.get(kept, "outfit"), name -> new ArrayList<>()).add(new Hold(
                        ((Double)lua.get(kept, "x")).floatValue(), ((Double)lua.get(kept, "y")).floatValue(), radius, radius + margin,
                        Boolean.TRUE.equals(lua.get(kept, "dissolve"))));
                }
            }
        var next = new HashMap<String, Hold[]>();
        for (var entry : byOutfit.entrySet()) next.put(entry.getKey(), entry.getValue().toArray(new Hold[0]));
        holds = Map.copyOf(next);
        if (hooked) Hooks.setZombieHolds(next.isEmpty() ? null : this);
    }

    /** The holds by outfit, for the tests. */
    Map<String, Hold[]> holds() { return holds; }

    // ---- the hooks: on the game's thread; nothing allocated ----

    /** The hold the zombie is in now: one of its outfit whose circle and margin it is within; or null. */
    private Hold holding(Object zombie) throws Throwable {
        Map<String, Hold[]> now = holds;
        if (now.isEmpty() || zombie == null) return null;
        String name = (String)outfit.invokeExact(zombie);
        Hold[] mine = name == null ? null : now.get(name);
        if (mine == null) return null;
        float x = (float)zombieX.invokeExact(zombie), y = (float)zombieY.invokeExact(zombie);
        for (Hold hold : mine) if (hold.near(x, y)) return hold;
        return null;
    }

    @Override public long wander(Object zombie, int x, int y) {
        try {
            Hold hold = holding(zombie);
            if (hold != null) {
                float dx = x + 0.5f - hold.x(), dy = y + 0.5f - hold.y();
                float distance = (float)Math.sqrt(dx * dx + dy * dy);
                // Outside the circle: the point on the line to the centre, a square inside the edge.
                if (distance > hold.radius()) {
                    float scale = Math.max(0f, hold.radius() - 1f) / distance;
                    x = (int)Math.floor(hold.x() + dx * scale);
                    y = (int)Math.floor(hold.y() + dy * scale);
                }
            }
        } catch (Throwable failure) { throw ZombieHolds.<RuntimeException>sneaky(failure); }
        return (long)x << 32 | y & 0xFFFFFFFFL;
    }

    @Override public boolean hears(Object sound, Object zombie) {
        try {
            Hold hold = holding(zombie);
            if (hold == null || (boolean)soundPlayer.invokeExact(sound)) return true;
            return hold.near((int)soundX.invokeExact(sound) + 0.5f, (int)soundY.invokeExact(sound) + 0.5f);
        } catch (Throwable failure) { throw ZombieHolds.<RuntimeException>sneaky(failure); }
    }

    @Override public boolean dissolves(Object zombie) {
        try {
            Map<String, Hold[]> now = holds;
            if (now.isEmpty() || zombie == null) return false;
            String name = (String)outfit.invokeExact(zombie);
            Hold[] mine = name == null ? null : now.get(name);
            if (mine == null) return false;
            for (Hold hold : mine) if (hold.dissolve()) return true;
            return false;
        } catch (Throwable failure) { throw ZombieHolds.<RuntimeException>sneaky(failure); }
    }

    // ---- the frame job ----

    /** A world left takes its holds with it. */
    void frame() throws ReflectiveOperationException {
        if (!moves.moved()) return;
        Object cell = game.cell();
        if (world != null && cell != world && lua.get(meta, KEPT) != null) {
            lua.set(meta, KEPT, null);
            update();
        }
        world = cell;
    }

    /** A fault: the hooks are given back and nothing is held, whatever the mods ask. Once; the rest of the API goes on. */
    void stop() {
        stopped = true;
        holds = Map.of();
        unhook();
    }

    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E sneaky(Throwable failure) throws E { throw (E)failure; }
}
