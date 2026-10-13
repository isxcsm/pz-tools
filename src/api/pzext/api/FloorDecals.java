package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Map;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.floor}: pictures a mod has drawn on the floor of squares (docs/design.md, "Floor decals"), such as a cable or a
 * pipe laid along the ground, without an object in the world: nothing is saved, nothing can be picked up, walked into or
 * searched, and the game's own objects are left as they are.
 *
 * <p>A decal is a sprite of the game's (a tile, by its name) and a tint. The chunk renderer draws a square's floor into its chunk
 * level's picture ({@code FBORenderCell.renderFloor(square)}, as the level is redrawn, not each frame); the hook at its return
 * draws the square's decals there, over the floor objects and under the snow, the blood and all that stands on the floor, as
 * {@code renderFloor} draws a floor object: the square's floor object as the object drawn (its depth, its offsets, its alpha), the
 * square's light for the player times the decal's tint, the depth not written (the floor's stays, so that whoever stands on a
 * decal is drawn over it). Setting a square's decals redraws its chunk level when the square is
 * loaded ({@code invalidateRenderChunkLevel(DIRTY_REDRAW)}); one that is not loaded is drawn as its chunk loads.
 *
 * <p>The decals belong to the world they were set in: leaving it takes them away. They are kept in the API table's metatable,
 * where a newer API takes them over. Everything here is on the game's thread: the Lua calls, the frame job and the hook (the
 * chunk renderer fills the render queue on the game's thread).
 */
final class FloorDecals implements Hooks.FloorDecals {
    /** The numbers and names a decal takes in a list: the sprite's name, then r, g, b, a (0 to 1). */
    static final int STRIDE = 5;
    /** The most decals a mod sets on a square, the most squares a mod has decals on, and the most for all mods. */
    static final int MAX_PER_SQUARE = 8, MAX_SQUARES_PER_MOD = 16384, MAX_SQUARES = 65536;
    /** FBORenderChunk.DIRTY_REDRAW: the chunk level is drawn again as it is. */
    static final long DIRTY_REDRAW = 1024L;
    /** The squares' coordinates a decal can be on: x and y within 24 bits, the level within 8. */
    static final int MAX_XY = (1 << 23) - 1, MIN_Z = -32, MAX_Z = 31;

    private static final String AREA = "PZExtAPI.floor.";
    // In the API's metatable: the decals (owner -> "x,y,z" -> list), the world they belong to, and which API runs them now.
    private static final String KEPT = "floorDecals", WORLD = "floorDecalsWorld", GENERATION = "floorDecalsGeneration";

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    // IsoSpriteManager.namedMap (the sprites the game knows by name); IsoGridSquare.x, y, z, getFloor(), getLightInfo(player),
    // invalidateRenderChunkLevel(flags); IsoObject.offsetX, offsetY; IsoCamera.frameState and its playerIndex.
    private final Map<?, ?> named;
    private final MethodHandle squareX, squareY, squareZ, floorOf, lightOf, invalidate, offsetX, offsetY, frameState, playerIndex;
    // ColorInfo.r, g, b, set(r, g, b, a); IsoSprite.render(object, x, y, z, dir, offsetX, offsetY, colour, prepare);
    // IndieGL.glDepthMask(on).
    private final MethodHandle red, green, blue, setColour, render, depthMask;
    private final Class<?> spriteType;
    private final Object north, colour;

    /** One mod's decals on one square: the sprites, their names, and a tint (r, g, b, a) for each. */
    private record Owned(String owner, Object[] sprites, String[] names, float[] tints) {
        boolean same(String[] otherNames, float[] otherTints) {
            return java.util.Arrays.equals(names, otherNames) && java.util.Arrays.equals(tints, otherTints);
        }
    }

    /** A square's decals: each mod's, and all of them in the order they are drawn (the mods in the order they first set it). */
    private static final class Square {
        final int x, y, z;
        final ArrayList<Owned> owned = new ArrayList<>(1);
        Object[] sprites = new Object[0];
        float[] tints = new float[0];

        Square(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }

        void flatten() {
            int count = 0;
            for (Owned each : owned) count += each.sprites.length;
            sprites = new Object[count];
            tints = new float[count * 4];
            int at = 0;
            for (Owned each : owned) {
                System.arraycopy(each.sprites, 0, sprites, at, each.sprites.length);
                System.arraycopy(each.tints, 0, tints, at * 4, each.tints.length);
                at += each.sprites.length;
            }
        }
    }

    private final Squares squares = new Squares();
    private final Map<String, Integer> perOwner = new java.util.HashMap<>();
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private long generation;
    private boolean reported;

    FloorDecals(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        var lookup = MethodHandles.publicLookup();
        Class<?> manager = Game.type(loader, "zombie.iso.sprite.IsoSpriteManager");
        named = (Map<?, ?>)manager.getField("namedMap").get(manager.getField("instance").get(null));
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare"), object = Game.type(loader, "zombie.iso.IsoObject");
        Class<?> colourType = Game.type(loader, "zombie.core.textures.ColorInfo"), camera = Game.type(loader, "zombie.iso.IsoCamera");
        Class<?> directions = Game.type(loader, "zombie.iso.IsoDirections");
        spriteType = Game.type(loader, "zombie.iso.sprite.IsoSprite");
        var intOf = MethodType.methodType(int.class, Object.class);
        var floatOf = MethodType.methodType(float.class, Object.class);
        squareX = lookup.unreflectGetter(square.getField("x")).asType(intOf);
        squareY = lookup.unreflectGetter(square.getField("y")).asType(intOf);
        squareZ = lookup.unreflectGetter(square.getField("z")).asType(intOf);
        floorOf = Game.exact(square.getMethod("getFloor"), MethodType.methodType(Object.class, Object.class));
        lightOf = Game.exact(square.getMethod("getLightInfo", int.class), MethodType.methodType(Object.class, Object.class, int.class));
        invalidate = Game.exact(square.getMethod("invalidateRenderChunkLevel", long.class), MethodType.methodType(void.class, Object.class, long.class));
        offsetX = lookup.unreflectGetter(object.getField("offsetX")).asType(floatOf);
        offsetY = lookup.unreflectGetter(object.getField("offsetY")).asType(floatOf);
        java.lang.reflect.Field state = camera.getField("frameState");
        frameState = lookup.unreflectGetter(state).asType(MethodType.methodType(Object.class));
        playerIndex = lookup.unreflectGetter(state.getType().getField("playerIndex")).asType(intOf);
        red = lookup.unreflectGetter(colourType.getField("r")).asType(floatOf);
        green = lookup.unreflectGetter(colourType.getField("g")).asType(floatOf);
        blue = lookup.unreflectGetter(colourType.getField("b")).asType(floatOf);
        setColour = Game.exact(colourType.getMethod("set", float.class, float.class, float.class, float.class),
            MethodType.methodType(Object.class, Object.class, float.class, float.class, float.class, float.class));
        render = Game.exact(spriteType.getMethod("render", object, float.class, float.class, float.class, directions, float.class, float.class,
            colourType, boolean.class), MethodType.methodType(void.class, Object.class, Object.class, float.class, float.class, float.class,
            Object.class, float.class, float.class, Object.class, boolean.class));
        depthMask = Game.exact(Game.type(loader, "zombie.IndieGL").getMethod("glDepthMask", boolean.class),
            MethodType.methodType(void.class, boolean.class));
        north = directions.getField("N").get(null);
        colour = colourType.getConstructor().newInstance();
        world = game.cell();
        load();
        // Takes the hook from an earlier API (or leaves it empty); a LinkageError with a bootstrap from before the decals.
        Hooks.setFloorDecals(squares.size() > 0 ? this : null);
    }

    /** The hook draws nothing. */
    static void unhook() {
        try { Hooks.setFloorDecals(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No decal is set in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Throwable; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            if (generation == 0 || generation(lua, meta) != generation)
                throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
            try { return body.call(call, arguments); }
            catch (RuntimeException | Error mine) { throw mine; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        }));
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        function(table, "set", (call, arguments) -> {
            String owner = owner(arguments, call);
            int x = Arguments.integer(arguments, 1, call, "x", -MAX_XY, MAX_XY);
            int y = Arguments.integer(arguments, 2, call, "y", -MAX_XY, MAX_XY);
            int z = Arguments.integer(arguments, 3, call, "z", MIN_Z, MAX_Z);
            Object list = arguments.length > 4 ? arguments[4] : null;
            Object[] sprites;
            String[] names;
            float[] tints;
            if (list == null) { sprites = new Object[0]; names = new String[0]; tints = new float[0]; }
            else {
                if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": list must be a table (a sprite's name, r, g, b, a for each decal) or nil");
                int length = lua.length(list);
                if (length % STRIDE != 0) throw new IllegalArgumentException(call + ": list must hold " + STRIDE + " values for each decal (a sprite's name, r, g, b, a); it holds " + length);
                int count = length / STRIDE;
                if (count > MAX_PER_SQUARE) throw new IllegalArgumentException(call + ": at most " + MAX_PER_SQUARE + " decals on a square; the list has " + count);
                sprites = new Object[count];
                names = new String[count];
                tints = new float[count * 4];
                for (int decal = 0; decal < count; decal++) {
                    int at = decal * STRIDE + 1;
                    Object name = lua.at(list, at);
                    Object sprite = name instanceof String text ? named.get(text) : null;
                    if (!spriteType.isInstance(sprite))
                        throw new IllegalArgumentException(call + ": list[" + at + "] must be the name of a sprite the game knows" + (name instanceof String text ? ", not '" + text + "'" : ""));
                    sprites[decal] = sprite;
                    names[decal] = (String)name;
                    for (int part = 0; part < 4; part++) {
                        if (!(lua.at(list, at + 1 + part) instanceof Double value) || !(value >= 0 && value <= 1))
                            throw new IllegalArgumentException(call + ": list[" + (at + 1 + part) + "] must be a number from 0 to 1");
                        tints[decal * 4 + part] = (float)(double)value;
                    }
                }
            }
            put(owner, x, y, z, new Owned(owner, sprites, names, tints), call);
            return Game.NONE;
        });
        function(table, "clear", (call, arguments) -> {
            clear(owner(arguments, call), call);
            return Game.NONE;
        });
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
        return owner;
    }

    /** {@code handle:clear()} and {@code floor.clear(handle)}: the mod's decals are taken away. */
    void clear(String owner, String call) throws Throwable {
        if (!perOwner.containsKey(owner)) return;
        for (Square square : squares.all()) {
            for (Owned each : square.owned) {
                if (!each.owner.equals(owner)) continue;
                put(owner, square.x, square.y, square.z, new Owned(owner, new Object[0], new String[0], new float[0]), call);
                break;
            }
        }
    }

    /** Sets a mod's decals on a square (none takes them away), redrawing its chunk level when they changed and it is loaded. */
    private void put(String owner, int x, int y, int z, Owned next, String call) throws Throwable {
        sameWorld();
        long key = key(x, y, z);
        Square square = squares.get(key);
        Owned before = null;
        if (square != null) for (Owned each : square.owned) if (each.owner.equals(owner)) before = each;
        boolean none = next.sprites.length == 0;
        if (before == null ? none : before.same(next.names, next.tints)) return;
        if (before == null) {
            int own = perOwner.getOrDefault(owner, 0);
            if (own >= MAX_SQUARES_PER_MOD) throw new IllegalArgumentException(call + ": the mod has decals on " + own + " squares; at most " + MAX_SQUARES_PER_MOD);
            if (square == null && squares.size() >= MAX_SQUARES) throw new IllegalArgumentException(call + ": the mods have decals on " + squares.size() + " squares; at most " + MAX_SQUARES);
            perOwner.put(owner, own + 1);
        }
        if (square == null) { square = new Square(x, y, z); squares.put(key, square); }
        int index = before == null ? -1 : square.owned.indexOf(before);
        if (none) {
            square.owned.remove(index);
            int own = perOwner.get(owner) - 1;
            if (own == 0) perOwner.remove(owner); else perOwner.put(owner, own);
        } else if (index >= 0) square.owned.set(index, next);
        else square.owned.add(next);
        if (square.owned.isEmpty()) squares.remove(key); else square.flatten();
        keep(owner, x, y, z, next);
        Hooks.setFloorDecals(squares.size() > 0 ? this : null);
        Object loaded = game.square(game.cell(), x, y, z);
        if (loaded != null) invalidate.invokeExact(loaded, DIRTY_REDRAW);
    }

    /** A world left takes the decals set in it away. */
    private void sameWorld() throws ReflectiveOperationException {
        Object cell = game.cell();
        if (cell == world) return;
        world = cell;
        squares.clear();
        perOwner.clear();
        lua.set(meta, KEPT, null);
        lua.set(meta, WORLD, cell);
        Hooks.setFloorDecals(null);
    }

    /** Each frame: a world left takes its decals away (looked at only when the world's cell was stored). */
    void frame() {
        if (squares.size() == 0 || !moves.moved()) return;
        try { sameWorld(); }
        catch (Throwable failure) {
            if (!reported) System.err.println("[PZExt] floor: " + failure);
            reported = true;
        }
    }

    // ---- kept for a newer API ----

    private void keep(String owner, int x, int y, int z, Owned decals) throws ReflectiveOperationException {
        Object all = lua.get(meta, KEPT);
        if (!lua.isTable(all)) { all = lua.table(); lua.set(meta, KEPT, all); lua.set(meta, WORLD, world); }
        Object mine = lua.get(all, owner);
        if (!lua.isTable(mine)) { mine = lua.table(); lua.set(all, owner, mine); }
        String at = x + "," + y + "," + z;
        if (decals.sprites.length == 0) { lua.set(mine, at, null); return; }
        Object list = lua.table();
        for (int decal = 0; decal < decals.sprites.length; decal++) {
            lua.set(list, (double)(decal * STRIDE + 1), decals.names[decal]);
            for (int part = 0; part < 4; part++) lua.set(list, (double)(decal * STRIDE + 2 + part), (double)decals.tints[decal * 4 + part]);
        }
        lua.set(mine, at, list);
    }

    /** What an earlier API kept, in this world; a sprite the game no longer knows is left out. */
    private void load() throws ReflectiveOperationException {
        Object all = lua.get(meta, KEPT);
        if (!lua.isTable(all)) return;
        if (lua.get(meta, WORLD) != world) { lua.set(meta, KEPT, null); return; }
        for (var mod : lua.entries(all)) {
            if (!(mod.getKey() instanceof String owner) || !lua.isTable(mod.getValue())) continue;
            for (var entry : lua.entries(mod.getValue())) {
                if (!(entry.getKey() instanceof String at) || !lua.isTable(entry.getValue())) continue;
                String[] parts = at.split(",");
                if (parts.length != 3) continue;
                int x, y, z;
                try { x = Integer.parseInt(parts[0]); y = Integer.parseInt(parts[1]); z = Integer.parseInt(parts[2]); }
                catch (NumberFormatException unreadable) { continue; }
                Object list = entry.getValue();
                var sprites = new ArrayList<Object>();
                var names = new ArrayList<String>();
                var tints = new ArrayList<Float>();
                for (int index = 1; lua.get(list, (double)index) instanceof String name; index += STRIDE) {
                    Object sprite = named.get(name);
                    if (!spriteType.isInstance(sprite)) continue;
                    sprites.add(sprite);
                    names.add(name);
                    for (int part = 0; part < 4; part++) tints.add(lua.get(list, (double)(index + 1 + part)) instanceof Double value ? (float)(double)value : 1f);
                }
                if (sprites.isEmpty()) continue;
                float[] tint = new float[tints.size()];
                for (int index = 0; index < tint.length; index++) tint[index] = tints.get(index);
                long key = key(x, y, z);
                Square square = squares.get(key);
                if (square == null) { square = new Square(x, y, z); squares.put(key, square); }
                square.owned.add(new Owned(owner, sprites.toArray(), names.toArray(new String[0]), tint));
                square.flatten();
                perOwner.merge(owner, 1, Integer::sum);
            }
        }
    }

    // ---- the hook: the game's thread, as a chunk level is drawn ----

    @Override
    public void square(Object at) throws Throwable {
        if (squares.size() == 0) return;
        int x = (int)squareX.invokeExact(at), y = (int)squareY.invokeExact(at), z = (int)squareZ.invokeExact(at);
        Square square = squares.get(key(x, y, z));
        if (square == null) return;
        Object floor = (Object)floorOf.invokeExact(at);
        if (floor == null) return;
        Object light = (Object)lightOf.invokeExact(at, (int)playerIndex.invokeExact((Object)frameState.invokeExact()));
        float r = (float)red.invokeExact(light), g = (float)green.invokeExact(light), b = (float)blue.invokeExact(light);
        float shiftX = (float)offsetX.invokeExact(floor), shiftY = (float)offsetY.invokeExact(floor);
        Object[] sprites = square.sprites;
        float[] tints = square.tints;
        // The floor's depth stays the floor's: a decal's own (a sprite without a depth map of its own) would stand in front
        // of the feet of whoever stands on it. renderFloor writes the depth for each floor object it draws.
        depthMask.invokeExact(false);
        try {
            for (int decal = 0; decal < sprites.length; decal++) {
                int tint = decal * 4;
                Object tinted = (Object)setColour.invokeExact(colour, r * tints[tint], g * tints[tint + 1], b * tints[tint + 2], tints[tint + 3]);
                render.invokeExact(sprites[decal], floor, (float)x, (float)y, (float)z, north, shiftX, shiftY, colour, true);
            }
        } finally {
            depthMask.invokeExact(true);
        }
    }

    /** How many squares have decals (for the tests). */
    int count() { return squares.size(); }

    private static long key(int x, int y, int z) {
        return (long)(x & 0xFFFFFF) << 32 | (long)(y & 0xFFFFFF) << 8 | z & 0xFF;
    }

    /** The squares with decals by their key: found without allocating, as the hook asks for every floor drawn. */
    private static final class Squares {
        private long[] keys = new long[16];
        private Square[] values = new Square[16];
        private int size;

        int size() { return size; }

        Square get(long key) {
            int mask = keys.length - 1;
            for (int slot = slot(key, mask);; slot = slot + 1 & mask) {
                Square value = values[slot];
                if (value == null) return null;
                if (keys[slot] == key) return value;
            }
        }

        void put(long key, Square value) {
            if ((size + 1) * 2 > keys.length) grow();
            int mask = keys.length - 1;
            int slot = slot(key, mask);
            while (values[slot] != null && keys[slot] != key) slot = slot + 1 & mask;
            if (values[slot] == null) size++;
            keys[slot] = key;
            values[slot] = value;
        }

        void remove(long key) {
            int mask = keys.length - 1;
            int slot = slot(key, mask);
            while (values[slot] != null && keys[slot] != key) slot = slot + 1 & mask;
            if (values[slot] == null) return;
            values[slot] = null;
            size--;
            // Moves back the entries after it that would not be found past the gap.
            for (int next = slot + 1 & mask; values[next] != null; next = next + 1 & mask) {
                int home = slot(keys[next], mask);
                if ((next - home & mask) >= (next - slot & mask)) {
                    keys[slot] = keys[next];
                    values[slot] = values[next];
                    values[next] = null;
                    slot = next;
                }
            }
        }

        void clear() {
            java.util.Arrays.fill(values, null);
            size = 0;
        }

        ArrayList<Square> all() {
            var list = new ArrayList<Square>(size);
            for (Square value : values) if (value != null) list.add(value);
            return list;
        }

        private void grow() {
            long[] oldKeys = keys;
            Square[] oldValues = values;
            keys = new long[oldKeys.length * 2];
            values = new Square[oldValues.length * 2];
            size = 0;
            for (int index = 0; index < oldKeys.length; index++) if (oldValues[index] != null) put(oldKeys[index], oldValues[index]);
        }

        private static int slot(long key, int mask) {
            long mixed = key * 0xBF58476D1CE4E5B9L;
            return (int)(mixed ^ mixed >>> 31) & mask;
        }
    }
}
