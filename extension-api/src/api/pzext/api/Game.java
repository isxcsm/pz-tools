package pzext.api;

import java.lang.invoke.*;
import java.lang.reflect.*;
import java.util.*;
import pzext.api.Network.Position;

/**
 * The game's world as the buildings and the networks reach it: the classes, methods and fields they share, resolved
 * once by reflection (the API is built without the game). Reading through them is safe on any thread the game asks
 * a question on.
 */
final class Game {
    final Class<?> objectType, lightSwitch, container;
    // (The squares, chunks and objects' squares are read through Reach's handles.)
    private final Field world, switchRoom;
    private final Method metaGrid, cell, objects, hasGrid, gridObjects;
    private final Method gameTime, worldHours, addEvent, raise, raiseTwo, raiseOne, raiseFour;
    /** The squares on a side of a chunk (IsoChunkMap.CHUNK_SIZE_IN_SQUARES). */
    final int chunkSize;
    /** The arguments of a call that takes none, for the hooks' calls: a call written without them allocates an array. */
    static final Object[] NONE = {};
    // The parts of an object that covers several squares, read into a list of the thread's own (see parts).
    private static final ThreadLocal<ArrayList<Object>> PARTS = ThreadLocal.withInitial(ArrayList::new);

    Game(ClassLoader loader) throws ReflectiveOperationException {
        Reach.Seed.set(loader);
        Reach.verify(loader);
        Class<?> worldType = type(loader, "zombie.iso.IsoWorld");
        Class<?> squareType = type(loader, "zombie.iso.IsoGridSquare");
        objectType = type(loader, "zombie.iso.IsoObject");
        lightSwitch = type(loader, "zombie.iso.objects.IsoLightSwitch");
        container = type(loader, "zombie.inventory.ItemContainer");
        world = worldType.getField("instance");
        metaGrid = worldType.getMethod("getMetaGrid");
        cell = worldType.getMethod("getCell");
        chunkSize = type(loader, "zombie.iso.IsoChunkMap").getField("CHUNK_SIZE_IN_SQUARES").getInt(null);
        objects = squareType.getMethod("getObjects");
        hasGrid = objectType.getMethod("hasSpriteGrid");
        gridObjects = objectType.getMethod("getSpriteGridObjectsIncludingSelf", ArrayList.class);
        switchRoom = lightSwitch.getField("roomId");
        Class<?> time = type(loader, "zombie.GameTime");
        gameTime = time.getMethod("getInstance");
        worldHours = time.getMethod("getWorldAgeHours");
        Class<?> events = type(loader, "zombie.Lua.LuaEventManager");
        addEvent = events.getMethod("AddEvent", String.class);
        raise = events.getMethod("triggerEvent", String.class, Object.class, Object.class, Object.class);
        raiseTwo = events.getMethod("triggerEvent", String.class, Object.class, Object.class);
        raiseOne = events.getMethod("triggerEvent", String.class, Object.class);
        raiseFour = events.getMethod("triggerEvent", String.class, Object.class, Object.class, Object.class, Object.class);
    }

    static Class<?> type(ClassLoader loader, String name) throws ClassNotFoundException {
        return Class.forName(name, false, loader);
    }

    static <T extends AccessibleObject> T accessible(T member) { member.setAccessible(true); return member; }

    /**
     * A public method of the game as a handle of the given type (its receiver and results as Object, its primitives
     * kept), for {@code invokeExact} on the hooks' paths: no argument array, no boxing.
     */
    static MethodHandle exact(Method method, MethodType type) throws IllegalAccessException {
        return MethodHandles.publicLookup().unreflect(method).asType(type);
    }

    /** A failure through a handle as through {@link Method#invoke}: the game's own exception in an InvocationTargetException. */
    static ReflectiveOperationException thrown(Throwable failure) {
        if (failure instanceof Error error) throw error;
        return failure instanceof ReflectiveOperationException reflective ? reflective : new InvocationTargetException(failure);
    }

    /**
     * A failure of the game behind a hook, as the hooks report it: the game's own exception for a method that threw,
     * which the bootstrap logs once and answers as vanilla.
     */
    static IllegalStateException failed(ReflectiveOperationException failure) {
        return new IllegalStateException(failure instanceof InvocationTargetException thrown ? thrown.getCause() : failure);
    }

    /** The game's current cell, or null when no world is loaded. */
    Object cell() throws ReflectiveOperationException {
        Object current = world.get(null);
        return current == null ? null : cell.invoke(current, NONE);
    }

    /** The map's rooms and buildings (IsoMetaGrid), for loaded and unloaded squares alike; null without a world. */
    Object metaGrid() throws ReflectiveOperationException {
        Object current = world.get(null);
        return current == null ? null : metaGrid.invoke(current);
    }

    /** The loaded square, or null. */
    Object square(Object cells, int x, int y, int z) throws ReflectiveOperationException {
        if (cells == null) return null;
        try { return (Object)Reach.GRID_SQUARE.invokeExact(cells, x, y, z); }
        catch (Throwable failure) { throw thrown(failure); }
    }

    Object square(Object cells, Position at) throws ReflectiveOperationException { return square(cells, at.x(), at.y(), at.z()); }

    /** The chunk a square is in, as one number (its chunk x in the high half, y in the low). */
    long chunkKey(int x, int y) {
        return (long)Math.floorDiv(x, chunkSize) << 32 | Math.floorDiv(y, chunkSize) & 0xffffffffL;
    }

    /** Whether the chunk {@link #chunkKey} names is loaded now. */
    boolean chunkLoaded(Object cells, long key) throws ReflectiveOperationException {
        if (cells == null) return false;
        try {
            Object chunk = (Object)Reach.CHUNK_AT.invokeExact(cells, (int)(key >> 32), (int)key);
            return chunk != null && (boolean)Reach.CHUNK_LOADED.invokeExact(chunk);
        } catch (Throwable failure) { throw thrown(failure); }
    }

    /** The square an object stands on, or null. */
    Object squareOf(Object object) throws ReflectiveOperationException {
        try { return (Object)Reach.SQUARE_OF.invokeExact(object); }
        catch (Throwable failure) { throw thrown(failure); }
    }

    int x(Object square) throws IllegalAccessException {
        try { return (int)Reach.SQUARE_X.invokeExact(square); }
        catch (Throwable failure) { throw read(failure); }
    }

    int y(Object square) throws IllegalAccessException {
        try { return (int)Reach.SQUARE_Y.invokeExact(square); }
        catch (Throwable failure) { throw read(failure); }
    }

    int z(Object square) throws IllegalAccessException {
        try { return (int)Reach.SQUARE_Z.invokeExact(square); }
        catch (Throwable failure) { throw read(failure); }
    }

    /** A failure reading a field through a handle, as {@link Field#getInt} gives it: the runtime errors as they are. */
    private static IllegalAccessException read(Throwable failure) {
        if (failure instanceof Error error) throw error;
        if (failure instanceof RuntimeException unchecked) throw unchecked;
        return new IllegalAccessException(failure.toString());
    }

    Position position(Object square) throws IllegalAccessException {
        return square == null ? null : new Position(x(square), y(square), z(square));
    }

    /** The object's square, or null when it is on none. */
    Position at(Object object) throws ReflectiveOperationException { return position(squareOf(object)); }

    /**
     * A square's objects as the game holds them, not copied: for the hooks' paths, read by index (PZArrayList has no
     * iterator) and through before anything changes the square.
     */
    List<?> objectList(Object square) throws ReflectiveOperationException { return (List<?>)objects.invoke(square, NONE); }

    /** A square's objects. The game's list (PZArrayList) is read by index: it has no iterator. */
    List<Object> objectsOn(Object square) throws ReflectiveOperationException {
        var list = objectList(square);
        var result = new ArrayList<Object>(list.size());
        for (int index = 0; index < list.size(); index++) result.add(list.get(index));
        return result;
    }

    /** Whether the object covers several squares. */
    boolean hasParts(Object object) throws ReflectiveOperationException { return (boolean)hasGrid.invoke(object, NONE); }

    /** The object and, for one that covers several squares, its other parts. */
    List<Object> parts(Object object) throws ReflectiveOperationException {
        if (!hasParts(object)) return List.of(object);
        @SuppressWarnings("unchecked")
        var parts = (List<Object>)gridObjects.invoke(object, new ArrayList<>());
        return parts.isEmpty() ? List.of(object) : parts;
    }

    /**
     * {@link #parts} for an object that covers several squares, without allocating: the list is the thread's own, valid
     * until the thread asks again, so the caller reads it through before it asks the game anything else.
     */
    List<Object> partsOnThisThread(Object object) throws ReflectiveOperationException {
        ArrayList<Object> parts = PARTS.get();
        parts.clear();
        @SuppressWarnings("unchecked")
        var result = (List<Object>)gridObjects.invoke(object, parts);
        return result.isEmpty() ? List.of(object) : result;
    }

    /** The room a light switch lights ({@code IsoLightSwitch.roomId}); -1 for none. */
    long switchRoom(Object lightSwitch) throws IllegalAccessException { return switchRoom.getLong(lightSwitch); }

    void setSwitchRoom(Object lightSwitch, long room) throws IllegalAccessException { switchRoom.setLong(lightSwitch, room); }

    /** The world's age in hours. */
    double hours() throws ReflectiveOperationException { return (double)worldHours.invoke(gameTime.invoke(null)); }

    /** Makes a Lua event known to the game's Lua. */
    void addEvent(String event) throws ReflectiveOperationException { addEvent.invoke(null, event); }

    /** Raises a Lua event ({@code LuaEventManager.triggerEvent}). */
    void raise(String event, Object first, Object second, Object third) throws ReflectiveOperationException {
        raise.invoke(null, event, first, second, third);
    }

    void raise(String event, Object first, Object second) throws ReflectiveOperationException {
        raiseTwo.invoke(null, event, first, second);
    }

    void raise(String event, Object first) throws ReflectiveOperationException {
        raiseOne.invoke(null, event, first);
    }

    void raise(String event, Object first, Object second, Object third, Object fourth) throws ReflectiveOperationException {
        raiseFour.invoke(null, event, first, second, third, fourth);
    }
}
