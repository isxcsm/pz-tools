// STUB: replaced by perf/squares at merge
package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;

/**
 * A condition table read once (docs/design.md, "Conditions on a square"): a square meets it when it meets every key. This is the
 * part of it {@code squares.path} needs for now: {@code free}, {@code floor}, {@code stairs}, {@code waterFlag}, {@code outside}
 * and {@code building} ({@code "none"} or {@code "any"}).
 */
final class SquareFilter {
    private static Handles handles;
    private final Handles game;
    private final Boolean free, floor, stairs, waterFlag, outside;
    private final String building;

    private static final class Handles {
        final Class<?> owner;
        final MethodHandle free, floor, stairs, properties, has, outside, building;
        final Object water;

        Handles(ClassLoader loader) throws ReflectiveOperationException {
            Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare"), flag = Game.type(loader, "zombie.iso.SpriteDetails.IsoFlagType");
            Class<?> container = Game.type(loader, "zombie.core.properties.PropertyContainer");
            owner = square;
            free = Game.exact(square.getMethod("isFree", boolean.class), MethodType.methodType(boolean.class, Object.class, boolean.class));
            floor = Game.exact(square.getMethod("getFloor"), MethodType.methodType(Object.class, Object.class));
            stairs = Game.exact(square.getMethod("HasStairs"), MethodType.methodType(boolean.class, Object.class));
            properties = Game.exact(square.getMethod("getProperties"), MethodType.methodType(Object.class, Object.class));
            has = Game.exact(container.getMethod("has", flag), MethodType.methodType(boolean.class, Object.class, Object.class));
            outside = Game.exact(square.getMethod("isOutside"), MethodType.methodType(boolean.class, Object.class));
            building = Game.exact(square.getMethod("getBuilding"), MethodType.methodType(Object.class, Object.class));
            water = flag.getField("water").get(null);
        }
    }

    private SquareFilter(Handles game, Boolean free, Boolean floor, Boolean stairs, Boolean waterFlag, Boolean outside, String building) {
        this.game = game; this.free = free; this.floor = floor; this.stairs = stairs; this.waterFlag = waterFlag; this.outside = outside;
        this.building = building;
    }

    /** The filter a table states; {@code null} (no table) passes every loaded square. */
    static SquareFilter read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (table == null) return null;
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": a filter must be a table");
        Handles handles = handles(game.objectType.getClassLoader());
        Object building = lua.get(table, "building");
        if (building != null && !"none".equals(building) && !"any".equals(building))
            throw new IllegalArgumentException(call + ": filter.building must be \"none\" or \"any\"");
        return new SquareFilter(handles, flag(lua, table, "free", call), flag(lua, table, "floor", call), flag(lua, table, "stairs", call),
            flag(lua, table, "waterFlag", call), flag(lua, table, "outside", call), (String)building);
    }

    private static synchronized Handles handles(ClassLoader loader) throws ReflectiveOperationException {
        if (handles == null || handles.owner.getClassLoader() != loader) handles = new Handles(loader);
        return handles;
    }

    private static Boolean flag(Kahlua lua, Object table, String name, String call) throws ReflectiveOperationException {
        Object value = lua.get(table, name);
        if (value != null && !(value instanceof Boolean)) throw new IllegalArgumentException(call + ": filter." + name + " must be true or false");
        return (Boolean)value;
    }

    /** Whether the (loaded) square meets every key. */
    boolean test(Object square) throws Throwable {
        if (free != null && free != (boolean)game.free.invokeExact(square, false)) return false;
        if (floor != null && floor != ((Object)game.floor.invokeExact(square) != null)) return false;
        if (stairs != null && stairs != (boolean)game.stairs.invokeExact(square)) return false;
        if (waterFlag != null && waterFlag != (boolean)game.has.invokeExact((Object)game.properties.invokeExact(square), game.water)) return false;
        if (outside != null && outside != (boolean)game.outside.invokeExact(square)) return false;
        if (building != null && "none".equals(building) != ((Object)game.building.invokeExact(square) == null)) return false;
        return true;
    }
}
