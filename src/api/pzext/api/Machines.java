package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/**
 * The machines mods declare: objects of a sprite whose power use a mod gives (see {@code machine.baseConsumption}). The
 * game asks every object two questions when a generator works out what it powers: whether the object could be powered
 * by a generator, and what it consumes. This answers them from the declaration, and puts machines that were in the world
 * before the declaration into the game's lists of objects a generator can reach.
 *
 * <p>The questions come on the game's thread, for each object on a square of the lists, when a generator is placed,
 * switched or changed, and when the buildings area reports an object; they read a map and a mod's data table, and
 * allocate nothing.
 */
final class Machines {
    private static final double MAX_FACTOR = 100;
    // The chunks around a player that are loaded: scanned for machines the game listed before the declaration.
    private static final int CHUNK_SIZE = 8;

    private final Game game;
    private final Players players;
    // IsoObject.getSpriteName(), getSprite(); IsoSprite.getName().
    private final MethodHandle spriteName, spriteOf, nameOf;
    // The numbers the objects' mod data holds under the load keys.
    private final ObjectData data;
    // IsoPlayer.getX(), getY().
    private final MethodHandle xOf, yOf;
    // IsoCell.getChunk(wx, wy); IsoChunk.getMinLevel(), getMaxLevel(), getSquaresForLevel(level), addObjectPoweredByGenerator(object).
    private final Method chunkAt, lowest, highest, squaresOf, listIn;
    // IsoGenerator.updateGenerator(square), and the width of the loaded area in chunks.
    private final Method update;
    private final Field gridWidth;

    Machines(ClassLoader loader, Game game, Players players) throws ReflectiveOperationException, IllegalAccessException {
        this.game = game;
        this.players = players;
        Class<?> object = game.objectType, sprite = Game.type(loader, "zombie.iso.sprite.IsoSprite");
        Class<?> chunk = Game.type(loader, "zombie.iso.IsoChunk");
        Class<?> moving = Game.type(loader, "zombie.iso.IsoMovingObject");
        spriteName = Game.exact(object.getMethod("getSpriteName"), MethodType.methodType(Object.class, Object.class));
        spriteOf = Game.exact(object.getMethod("getSprite"), MethodType.methodType(Object.class, Object.class));
        nameOf = Game.exact(sprite.getMethod("getName"), MethodType.methodType(Object.class, Object.class));
        data = new ObjectData(loader, object);
        xOf = Game.exact(moving.getMethod("getX"), MethodType.methodType(float.class, Object.class));
        yOf = Game.exact(moving.getMethod("getY"), MethodType.methodType(float.class, Object.class));
        chunkAt = Game.type(loader, "zombie.iso.IsoCell").getMethod("getChunk", int.class, int.class);
        lowest = chunk.getMethod("getMinLevel");
        highest = chunk.getMethod("getMaxLevel");
        squaresOf = chunk.getMethod("getSquaresForLevel", int.class);
        listIn = chunk.getMethod("addObjectPoweredByGenerator", object);
        update = Game.type(loader, "zombie.iso.objects.IsoGenerator").getMethod("updateGenerator", Game.type(loader, "zombie.iso.IsoGridSquare"));
        gridWidth = Game.type(loader, "zombie.iso.IsoChunkMap").getField("chunkGridWidth");
    }

    /**
     * The name objects are known by (the object's sprite name, or its sprite's, as the buildings area gives it), or null.
     * Allocates nothing.
     */
    String name(Object object) throws Throwable {
        Object name = (Object)spriteName.invokeExact(object);
        if (name == null) {
            Object sprite = (Object)spriteOf.invokeExact(object);
            if (sprite != null) name = (Object)nameOf.invokeExact(sprite);
        }
        return (String)name;
    }

    /** The consumption declared for the object's sprite, or null when it is not a declared machine. */
    Float base(Map<String, Float> machines, Object object) throws Throwable {
        String name = name(object);
        return name == null ? null : machines.get(name);
    }

    /**
     * What the object's own load multiplies its consumption by: each of the keys the object's data table holds a number
     * under multiplies it (a number below 0 counts as 0, above 100 as 100; anything else is left out), 1 for none.
     */
    float factor(String[] keys, Object object) throws Throwable { return (float)data.product(keys, object, MAX_FACTOR); }

    /** Whether the object's data table holds a number other than 0 under one of the keys (machine.onKey). */
    boolean on(String[] keys, Object object) throws Throwable { return data.holds(keys, object); }

    /**
     * Lists the machines of these sprite names that are on loaded squares in the game's lists of objects a generator
     * can power, which the game fills as an object enters the world (so a machine that was there before the declaration is
     * not in them), and tells the generators near them. A world and a player are needed to know what is loaded: false when
     * there is none yet, for a later frame to try again.
     */
    boolean list(Set<String> names) throws Throwable {
        Object cell = game.cell();
        if (cell == null) return false;
        var squares = new LinkedHashSet<Object>();
        var scanned = new HashSet<Long>();
        boolean player = false;
        int radius = gridWidth.getInt(null) / 2 + 1;
        for (Object who : players.all()) {
            if (who == null) continue;
            player = true;
            int cx = Math.floorDiv((int)Math.floor((float)xOf.invokeExact(who)), CHUNK_SIZE);
            int cy = Math.floorDiv((int)Math.floor((float)yOf.invokeExact(who)), CHUNK_SIZE);
            for (int dy = -radius; dy <= radius; dy++)
                for (int dx = -radius; dx <= radius; dx++) {
                    if (!scanned.add((long)(cx + dx) << 32 | (cy + dy) & 0xFFFFFFFFL)) continue;
                    Object chunk = chunkAt.invoke(cell, cx + dx, cy + dy);
                    if (chunk != null) scan(chunk, names, squares);
                }
        }
        if (!player) return false;
        for (Object square : squares) update.invoke(null, square);
        return true;
    }

    private void scan(Object chunk, Set<String> names, Set<Object> squares) throws Throwable {
        for (int level = (int)lowest.invoke(chunk), top = (int)highest.invoke(chunk); level <= top; level++) {
            Object[] found = (Object[])squaresOf.invoke(chunk, level);
            if (found == null) continue;
            for (Object square : found) {
                if (square == null) continue;
                var objects = game.objectList(square);
                for (int at = 0; at < objects.size(); at++) {
                    Object object = objects.get(at);
                    String name = name(object);
                    if (name == null || !names.contains(name)) continue;
                    listIn.invoke(chunk, object);
                    squares.add(square);
                }
            }
        }
    }
}
