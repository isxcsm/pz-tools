package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.zombies.mark}, {@code unmark}, {@code markOf}, {@code marked}, {@code forget}, {@code hold} and {@code release}
 * (docs/design.md, "Zombie marks and holds"): a mod marks the zombies it put somewhere with a key of its own, finds them by it, and
 * keeps those of a key in an area: an idle one wanders within the circle, one heard only the sounds of players and of the area while
 * it is near, and, when the mod asks, one goes as its chunk unloads instead of staying as a virtual zombie the game moves about unseen.
 *
 * <p>A mark is kept in the zombie's modData (a table of mod -> key), which the game copies to its corpse, and in the world's global
 * ModData by the zombie's persistent number, which the game keeps while the zombie is virtual and in the save: a zombie that comes
 * into the world again with its number has its marks back. A zombie's marks go as it leaves the world (its object is kept for
 * another zombie); the world's go as it dies (the game lets a dead zombie go from the population before its corpse is made, and
 * takes its number away), as a hold lets it go, and when the mod forgets the key.
 *
 * <p>The holds are read by three hooks: where {@code ZombieIdleState} sends an idle zombie (a target outside the circle is brought in
 * along the line to its centre), each sound {@code WorldSoundManager.getBiggestSoundZomb} weighs (one the zombie must not hear is
 * skipped, as the game skips a missing one), and each zombie {@code ZombiePopulationManager.removeChunkFromWorld} would keep virtual (one
 * that goes is released from the population instead). A zombie is held while it is within the circle and its margin; one that chased a
 * player further is the game's until it comes back. With no hold, those hooks return after one volatile read; with no mark in the
 * world, those of a zombie coming and going after a lookup of the world's table.
 *
 * <p>Threads. The first two are asked on whatever thread the game runs the zombie's update and the sound weighing on (PZ Optimization
 * does both on its frame workers, beside the game's thread, which writes marks from Lua at the same time), so they read no Lua table:
 * only the holds ({@link #holds}, replaced whole) and the marks of the loaded zombies as Java-side snapshots ({@link #byZombie}, a zombie's
 * entry replaced whole each time its marks change). Both are written on the game's thread alone: by the Lua calls, by the hooks of a
 * zombie coming and going, and as the holds or the world change. The third (a chunk unloading) and those of a zombie coming and going
 * also change the world's table and a zombie's modData, which are Lua tables: they are asked on the game's thread only.
 *
 * <p>The holds belong to the world they were made in, and are kept in the API table's metatable, where a newer API takes them over.
 */
final class ZombieHolds implements Hooks.ZombieHolds {
    static final int MAX_PER_MOD = 64, MAX_MARKS_PER_MOD = 5000, MAX_RADIUS = 300, MAX_MARGIN = 300, DEFAULT_MARGIN = 20;
    /** The key of the marks in a zombie's modData, and the name of the world's table of them. */
    static final String MARKS = "PZExtMarks";

    private static final String AREA = "PZExtAPI.zombies.";
    // In the API's metatable: the holds (owner -> key -> { x, y, radius, margin, dissolve }), and which API runs them.
    private static final String KEPT = "zombieHolds", GENERATION = "zombieHoldsGeneration";

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final Class<?> zombieType, objectType, tableType;
    private final MethodHandle zombieX, zombieY, soundX, soundY, soundPlayer;
    private final MethodHandle hasData, data, rawget, rawset, dead, persistent, square, worldTable, worldTableMade, zombieList;

    /** One hold as the hooks read it. */
    record Hold(float x, float y, float radius, float reach, boolean dissolve) {
        boolean near(float px, float py) {
            float dx = px - x, dy = py - y;
            return dx * dx + dy * dy <= reach * reach;
        }
    }

    /** A mod's holds by key. */
    record Owned(String owner, Map<String, Hold> holds) { }

    // The holds by mod; empty while none. Replaced whole, on the game's thread; read on any thread.
    private volatile Owned[] holds = new Owned[0];
    // The loaded zombies' marks as the hooks read them, by zombie: owner, key, owner, key... (a Lua table is read on the game's thread
    // alone). An entry is replaced whole, never changed; a zombie with no marks has none. Written on the game's thread alone.
    private final ConcurrentHashMap<Object, String[]> byZombie = new ConcurrentHashMap<>();
    private boolean hooked, stopped;
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private long generation;
    // The world's table of marks as last read, the numbers in it, and how many each mod has.
    private Object saved;
    private final Numbers numbers = new Numbers();
    private final HashMap<String, Integer> counts = new HashMap<>();

    ZombieHolds(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        var lookup = MethodHandles.publicLookup();
        zombieType = Game.type(loader, "zombie.characters.IsoZombie");
        objectType = Game.type(loader, "zombie.iso.IsoObject");
        tableType = Game.type(loader, "se.krka.kahlua.vm.KahluaTable");
        Class<?> sound = Game.type(loader, "zombie.WorldSoundManager$WorldSound"), modData = Game.type(loader, "zombie.world.moddata.ModData");
        MethodType onObject = MethodType.methodType(Object.class, Object.class), test = MethodType.methodType(boolean.class, Object.class);
        zombieX = Game.exact(zombieType.getMethod("getX"), MethodType.methodType(float.class, Object.class));
        zombieY = Game.exact(zombieType.getMethod("getY"), MethodType.methodType(float.class, Object.class));
        soundX = lookup.unreflectGetter(sound.getField("x")).asType(MethodType.methodType(int.class, Object.class));
        soundY = lookup.unreflectGetter(sound.getField("y")).asType(MethodType.methodType(int.class, Object.class));
        soundPlayer = lookup.unreflectGetter(sound.getField("sourceIsPlayer")).asType(test);
        hasData = Game.exact(objectType.getMethod("hasModData"), test);
        data = Game.exact(objectType.getMethod("getModData"), onObject);
        rawget = Game.exact(tableType.getMethod("rawget", Object.class), MethodType.methodType(Object.class, Object.class, Object.class));
        rawset = Game.exact(tableType.getMethod("rawset", Object.class, Object.class),
            MethodType.methodType(void.class, Object.class, Object.class, Object.class));
        dead = Game.exact(zombieType.getMethod("isDead"), test);
        persistent = lookup.unreflectGetter(zombieType.getField("persistentId")).asType(MethodType.methodType(int.class, Object.class));
        square = Game.exact(zombieType.getMethod("getCurrentSquare"), onObject);
        worldTable = Game.exact(modData.getMethod("get", String.class), MethodType.methodType(Object.class, String.class));
        worldTableMade = Game.exact(modData.getMethod("getOrCreate", String.class), MethodType.methodType(Object.class, String.class));
        zombieList = Game.exact(Game.type(loader, "zombie.iso.IsoCell").getMethod("getZombieList"), onObject);
        world = game.cell();
    }

    /** Takes the game's hooks. Throws a LinkageError with a bootstrap from before the marks. */
    void hook() throws ReflectiveOperationException {
        hooked = true;
        try { remember(); }
        catch (ReflectiveOperationException | RuntimeException unreadable) { throw unreadable; }
        catch (Throwable failure) { throw new IllegalStateException(failure); }
        update();
    }

    /** No zombie is marked or held: the hooks answer as the game. */
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

    /** The functions this sets into the zombies' table. */
    static final String[] FUNCTIONS = { "mark", "unmark", "markOf", "marked", "forget", "hold", "release" };

    // ---- the Lua surface ----

    /** Sets the functions into the zombies' table, replacing an earlier API's. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        define(table, "mark", (call, owner, arguments) -> {
            Object zombie = zombie(arguments, call);
            mark(owner, zombie, Arguments.name(arguments, 2, call, "key"), call);
            return new Object[0];
        });
        define(table, "unmark", (call, owner, arguments) -> {
            unmark(owner, object(arguments, call));
            return new Object[0];
        });
        define(table, "markOf", (call, owner, arguments) -> new Object[] { markOf(owner, object(arguments, call)) });
        define(table, "marked", (call, owner, arguments) -> new Object[] { marked(owner, Arguments.name(arguments, 1, call, "key")) });
        define(table, "forget", (call, owner, arguments) -> {
            forget(owner, Arguments.name(arguments, 1, call, "key"));
            return new Object[0];
        });
        define(table, "hold", (call, owner, arguments) -> {
            String key = Arguments.name(arguments, 1, call, "key");
            Object spec = arguments.length > 2 ? arguments[2] : null;
            if (!lua.isTable(spec)) throw new IllegalArgumentException(call + ": the hold must be a table");
            double x = number(lua.get(spec, "x"), call, "x", -SquareWatches.MAX_COORDINATE, SquareWatches.MAX_COORDINATE);
            double y = number(lua.get(spec, "y"), call, "y", -SquareWatches.MAX_COORDINATE, SquareWatches.MAX_COORDINATE);
            double radius = number(lua.get(spec, "radius"), call, "radius", 1, MAX_RADIUS);
            Object marginValue = lua.get(spec, "margin");
            double margin = marginValue == null ? DEFAULT_MARGIN : number(marginValue, call, "margin", 0, MAX_MARGIN);
            Object dissolve = lua.get(spec, "dissolve");
            if (dissolve != null && !(dissolve instanceof Boolean)) throw new IllegalArgumentException(call + ": dissolve must be true or false");
            Object mine = mine(owner, true);
            if (lua.get(mine, key) == null && count(mine) >= MAX_PER_MOD)
                throw new IllegalArgumentException(call + ": a mod holds " + MAX_PER_MOD + " areas at most");
            Object kept = lua.table();
            lua.set(kept, "x", x); lua.set(kept, "y", y); lua.set(kept, "radius", radius); lua.set(kept, "margin", margin);
            lua.set(kept, "dissolve", Boolean.TRUE.equals(dissolve));
            lua.set(mine, key, kept);
            update();
            return new Object[0];
        });
        define(table, "release", (call, owner, arguments) -> {
            String key = Arguments.name(arguments, 1, call, "key");
            Object mine = mine(owner, false);
            if (mine != null && lua.get(mine, key) != null) {
                lua.set(mine, key, null);
                update();
            }
            return new Object[0];
        });
    }

    @FunctionalInterface private interface Body { Object[] call(String call, String owner, Object[] arguments) throws Throwable; }

    private void define(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
            if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
            try { return body.call(call, owner, arguments); }
            catch (Exception | Error passed) { throw passed; }
            catch (Throwable other) { throw new IllegalStateException(other); }
        }));
    }

    private Object zombie(Object[] arguments, String call) throws Throwable {
        Object zombie = arguments.length > 1 ? arguments[1] : null;
        if (!zombieType.isInstance(zombie) || (boolean)dead.invokeExact(zombie))
            throw new IllegalArgumentException(call + ": the second argument must be a living zombie");
        return zombie;
    }

    private Object object(Object[] arguments, String call) {
        Object object = arguments.length > 1 ? arguments[1] : null;
        if (!objectType.isInstance(object)) throw new IllegalArgumentException(call + ": the second argument must be a zombie or a corpse");
        return object;
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

    // ---- the marks ----

    /** The object's marks (mod -> key), or null. */
    private Object marks(Object object) throws Throwable {
        if (!(boolean)hasData.invokeExact(object)) return null;
        Object marks = (Object)rawget.invokeExact((Object)data.invokeExact(object), (Object)MARKS);
        return tableType.isInstance(marks) ? marks : null;
    }

    /** The world's table of marks (persistent number -> the zombie's marks), made when {@code make}; read again when it is another. */
    private Object saved(boolean make) throws Throwable {
        Object table = make ? (Object)worldTableMade.invokeExact(MARKS) : (Object)worldTable.invokeExact(MARKS);
        if (table != saved) reread(table);
        return table;
    }

    private void reread(Object table) throws ReflectiveOperationException {
        saved = table;
        numbers.clear();
        counts.clear();
        if (table == null) return;
        for (var entry : lua.entries(table)) {
            if (!(entry.getKey() instanceof Double id) || !lua.isTable(entry.getValue())) continue;
            numbers.add(id.intValue());
            for (var mark : lua.entries(entry.getValue())) if (mark.getKey() instanceof String owner) counts.merge(owner, 1, Integer::sum);
        }
    }

    private void mark(String owner, Object zombie, String key, String call) throws Throwable {
        Object marks = marks(zombie);
        int id = (int)persistent.invokeExact(zombie);
        // The world keeps a zombie with a number (a client's have none); a mod's mark counts once.
        Object table = id != 0 ? saved(true) : null;
        Object kept = table == null ? null : lua.get(table, (double)id);
        if (table != null && !(lua.isTable(kept) && lua.get(kept, owner) != null)) {
            if (counts.getOrDefault(owner, 0) >= MAX_MARKS_PER_MOD)
                throw new IllegalArgumentException(call + ": a mod marks " + MAX_MARKS_PER_MOD + " zombies at most");
            counts.merge(owner, 1, Integer::sum);
        }
        if (marks == null) {
            marks = lua.table();
            lua.set((Object)data.invokeExact(zombie), MARKS, marks);
        }
        lua.set(marks, owner, key);
        if (table != null) {
            lua.set(table, (double)id, marks);
            numbers.add(id);
        }
        note(zombie);
    }

    private void unmark(String owner, Object object) throws Throwable {
        Object marks = marks(object);
        if (marks == null || lua.get(marks, owner) == null) return;
        lua.set(marks, owner, null);
        boolean live = zombieType.isInstance(object);
        if (live) note(object);
        int id = live ? (int)persistent.invokeExact(object) : 0;
        if (id != 0 && saved(false) != null && numbers.contains(id)) counts.merge(owner, -1, Integer::sum);
        if (!empty(marks)) return;
        lua.set((Object)data.invokeExact(object), MARKS, null);
        if (live) note(object);
        if (id != 0 && saved != null && numbers.contains(id)) {
            lua.set(saved, (double)id, null);
            numbers.remove(id);
        }
    }

    private Object markOf(String owner, Object object) throws Throwable {
        Object marks = marks(object);
        return marks == null ? null : lua.get(marks, owner);
    }

    /** The loaded living zombies the mod marked with the key, as a Lua list. */
    private Object marked(String owner, String key) throws Throwable {
        Object list = lua.table();
        Object cell = game.cell();
        if (cell == null) return list;
        int found = 0;
        for (Object zombie : (List<?>)(Object)zombieList.invokeExact(cell)) {
            if (zombie == null || (boolean)dead.invokeExact(zombie) || (Object)square.invokeExact(zombie) == null) continue;
            Object marks = marks(zombie);
            if (marks != null && key.equals(lua.get(marks, owner))) lua.set(list, (double)++found, zombie);
        }
        return list;
    }

    /** The mod's marks of the key go from the world and the loaded zombies; corpses keep theirs. */
    private void forget(String owner, String key) throws Throwable {
        Object table = saved(false);
        if (table != null) {
            var ids = new ArrayList<Double>();
            for (var entry : lua.entries(table))
                if (entry.getKey() instanceof Double id && lua.isTable(entry.getValue()) && key.equals(lua.get(entry.getValue(), owner))) ids.add(id);
            for (Double id : ids) {
                Object marks = lua.get(table, id);
                lua.set(marks, owner, null);
                counts.merge(owner, -1, Integer::sum);
                if (empty(marks)) {
                    lua.set(table, id, null);
                    numbers.remove(id.intValue());
                }
            }
        }
        Object cell = game.cell();
        if (cell == null) return;
        for (Object zombie : (List<?>)(Object)zombieList.invokeExact(cell)) {
            Object marks = zombie == null ? null : marks(zombie);
            if (marks == null || !key.equals(lua.get(marks, owner))) continue;
            lua.set(marks, owner, null);
            if (empty(marks)) lua.set((Object)data.invokeExact(zombie), MARKS, null);
            note(zombie);
        }
    }

    // ---- the marks as the hooks that run on any thread read them ----

    /** The snapshot of the zombie's marks made again from its modData (the game's thread): none if it has none. */
    private void note(Object zombie) throws Throwable {
        Object marks = marks(zombie);
        String[] pairs = marks == null ? null : pairs(marks);
        if (pairs == null || pairs.length == 0) byZombie.remove(zombie);
        else byZombie.put(zombie, pairs);
    }

    private String[] pairs(Object marks) throws ReflectiveOperationException {
        var list = new ArrayList<String>();
        for (var mark : lua.entries(marks))
            if (mark.getKey() instanceof String owner && mark.getValue() instanceof String key) { list.add(owner); list.add(key); }
        return list.toArray(new String[0]);
    }

    /** The snapshots made again from the loaded zombies (the world is a new one, or this API takes over from an earlier one). */
    private void remember() throws Throwable {
        byZombie.clear();
        Object cell = game.cell();
        if (cell == null) return;
        for (Object zombie : (List<?>)(Object)zombieList.invokeExact(cell)) if (zombie != null && marks(zombie) != null) note(zombie);
    }

    private boolean empty(Object table) throws ReflectiveOperationException {
        for (var entry : lua.entries(table)) if (entry.getValue() != null) return false;
        return true;
    }

    /** The world forgets the zombie's number: it died or was let go. */
    private void drop(int id, Object marks) throws Throwable {
        if (id == 0 || saved(false) == null || !numbers.contains(id)) return;
        for (var mark : lua.entries(marks)) if (mark.getKey() instanceof String owner) counts.merge(owner, -1, Integer::sum);
        lua.set(saved, (double)id, null);
        numbers.remove(id);
    }

    /** The world's marks, for the tests: how many zombies, and the mod's count. */
    int markedInWorld() { return numbers.size(); }
    int marksOf(String owner) { return counts.getOrDefault(owner, 0); }

    // ---- the holds ----

    /** The mod's holds (key -> hold), made when {@code make}; else null when it has none. */
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

    /** {@code handle:clear()}: the mod holds nothing (its marks stay: they belong to the world). */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        Object all = lua.get(meta, KEPT);
        if (!lua.isTable(all) || lua.get(all, owner) == null) return;
        lua.set(all, owner, null);
        update();
    }

    /** The holds as the hooks read them, made again from the kept ones; the hooks are taken while the API runs. */
    private void update() throws ReflectiveOperationException {
        if (stopped) return;
        var next = new ArrayList<Owned>();
        Object all = lua.get(meta, KEPT);
        if (lua.isTable(all))
            for (var owner : lua.entries(all)) {
                if (!(owner.getKey() instanceof String name) || !lua.isTable(owner.getValue())) continue;
                var byKey = new HashMap<String, Hold>();
                for (var entry : lua.entries(owner.getValue())) {
                    Object kept = entry.getValue();
                    if (!(entry.getKey() instanceof String key) || !lua.isTable(kept)) continue;
                    float radius = ((Double)lua.get(kept, "radius")).floatValue(), margin = ((Double)lua.get(kept, "margin")).floatValue();
                    byKey.put(key, new Hold(((Double)lua.get(kept, "x")).floatValue(), ((Double)lua.get(kept, "y")).floatValue(), radius,
                        radius + margin, Boolean.TRUE.equals(lua.get(kept, "dissolve"))));
                }
                if (!byKey.isEmpty()) next.add(new Owned(name, Map.copyOf(byKey)));
            }
        holds = next.toArray(new Owned[0]);
        if (hooked) Hooks.setZombieHolds(this);
    }

    /** The holds by mod, for the tests. */
    Owned[] holds() { return holds; }

    /** How many zombies have a snapshot of their marks, for the tests. */
    int snapshots() { return byZombie.size(); }

    // ---- the hooks: on the game's thread; nothing allocated on the common paths ----

    /** The hold the zombie is in now: one of a key it is marked with, whose circle and margin it is within; or null. */
    private Hold holding(Object zombie) throws Throwable {
        Owned[] now = holds;
        if (now.length == 0 || zombie == null) return null;
        String[] pairs = byZombie.get(zombie);
        if (pairs == null) return null;
        float x = (float)zombieX.invokeExact(zombie), y = (float)zombieY.invokeExact(zombie);
        for (int at = 0; at < pairs.length; at += 2)
            for (Owned owned : now) {
                if (!owned.owner().equals(pairs[at])) continue;
                Hold hold = owned.holds().get(pairs[at + 1]);
                if (hold != null && hold.near(x, y)) return hold;
            }
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
            Owned[] now = holds;
            if (now.length == 0 || zombie == null) return false;
            String[] pairs = byZombie.get(zombie);
            if (pairs == null) return false;
            for (int at = 0; at < pairs.length; at += 2)
                for (Owned owned : now) {
                    if (!owned.owner().equals(pairs[at])) continue;
                    Hold hold = owned.holds().get(pairs[at + 1]);
                    if (hold != null && hold.dissolve()) {
                        // The world's table and the zombie's modData are Lua tables: the game's thread, as a chunk unloading is.
                        Object marks = marks(zombie);
                        if (marks != null) drop((int)persistent.invokeExact(zombie), marks);
                        return true;
                    }
                }
            return false;
        } catch (Throwable failure) { throw ZombieHolds.<RuntimeException>sneaky(failure); }
    }

    @Override public void registered(Object zombie, int id) throws Throwable {
        if (id == 0 || zombie == null) return;
        Object table = (Object)worldTable.invokeExact(MARKS);
        if (table != null) {
            if (table != saved) reread(table);
            if (numbers.contains(id)) {
                Object marks = lua.get(table, (double)id);
                if (lua.isTable(marks)) lua.set((Object)data.invokeExact(zombie), MARKS, marks);
            }
        }
        // Marks it came with (its own modData, loaded with it) are held as the world's are.
        if (marks(zombie) != null) note(zombie);
    }

    @Override public void released(Object zombie) throws Throwable {
        // A dead zombie: the world forgets it (its object keeps the marks for the corpse). A living one goes virtual or was let go.
        if (zombie == null || !(boolean)dead.invokeExact(zombie)) return;
        byZombie.remove(zombie);
        Object marks = marks(zombie);
        if (marks != null) drop((int)persistent.invokeExact(zombie), marks);
    }

    @Override public void removed(Object zombie) throws Throwable {
        if (zombie == null) return;
        byZombie.remove(zombie);
        Object marks = marks(zombie);
        if (marks == null) return;
        // A corpse took its copy already; a virtual zombie keeps its marks in the world's table.
        if ((boolean)dead.invokeExact(zombie)) drop((int)persistent.invokeExact(zombie), marks);
        rawset.invokeExact((Object)data.invokeExact(zombie), (Object)MARKS, (Object)null);
    }

    // ---- the frame job ----

    /** A world left takes its holds with it. */
    void frame() throws ReflectiveOperationException {
        if (!moves.moved()) return;
        Object cell = game.cell();
        if (world != null && cell != world) {
            // The zombies of the world left are not this one's: their snapshots go (this one's come with its zombies).
            byZombie.clear();
            if (lua.get(meta, KEPT) != null) {
                lua.set(meta, KEPT, null);
                update();
            }
        }
        world = cell;
    }

    /** A fault: the hooks are given back and nothing is held, whatever the mods ask. Once; the rest of the API goes on. */
    void stop() {
        stopped = true;
        holds = new Owned[0];
        byZombie.clear();
        unhook();
    }

    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E sneaky(Throwable failure) throws E { throw (E)failure; }

    /** A set of non-zero ints, open addressed: looked up without boxing. */
    static final class Numbers {
        private int[] slots = new int[16];
        private int size;

        int size() { return size; }

        void clear() { java.util.Arrays.fill(slots, 0); size = 0; }

        boolean contains(int value) {
            int mask = slots.length - 1;
            for (int index = mix(value) & mask; ; index = index + 1 & mask) {
                int slot = slots[index];
                if (slot == value) return true;
                if (slot == 0) return false;
            }
        }

        void add(int value) {
            if (value == 0 || contains(value)) return;
            if ((size + 1) * 2 > slots.length) {
                int[] old = slots;
                slots = new int[old.length * 2];
                size = 0;
                for (int slot : old) if (slot != 0) put(slot);
            }
            put(value);
        }

        private void put(int value) {
            int mask = slots.length - 1, index = mix(value) & mask;
            while (slots[index] != 0) index = index + 1 & mask;
            slots[index] = value;
            size++;
        }

        void remove(int value) {
            int mask = slots.length - 1, index = mix(value) & mask;
            while (slots[index] != value) {
                if (slots[index] == 0) return;
                index = index + 1 & mask;
            }
            slots[index] = 0;
            size--;
            // The ones after it in the run are put again, so none is cut off from its place.
            for (int next = index + 1 & mask; slots[next] != 0; next = next + 1 & mask) {
                int moved = slots[next];
                slots[next] = 0;
                size--;
                put(moved);
            }
        }

        private static int mix(int value) { return value * 0x9E3779B9 >>> 7 ^ value; }
    }
}
