package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.List;

/**
 * What the world queries ask of a square, its objects and the map, as method handles that are constants of the compiled code
 * (see {@link Reach}): called exactly, so that asking a square costs no argument array and boxes nothing. Made once from the
 * game's classes; {@link #verify} turns a game this cannot read into a {@link ReflectiveOperationException}.
 */
final class SquareFacts {
    private static final MethodType OBJECT_OF = MethodType.methodType(Object.class, Object.class);
    private static final MethodType FLAG_OF = MethodType.methodType(boolean.class, Object.class);

    // IsoGridSquare: isFree(false), TreatAsSolidFloor(), getFloor(), isWaterSquare(), isOutside(), HasStairs(), HasTree(),
    // isVehicleIntersecting(), getVehicleContainer(), getMovingObjects(), getObjects(), getCell(), getRoom(), getBuilding().
    static final MethodHandle IS_FREE, SOLID_FLOOR, FLOOR, WATER_SQUARE, OUTSIDE, STAIRS, TREE, VEHICLE_OVER, VEHICLE_ON, MOVING,
        OBJECTS, CELL, ROOM, BUILDING;
    // IsoGridSquare.has(IsoFlagType) and isBlockedTo(IsoGridSquare).
    static final MethodHandle HAS_FLAG, BLOCKED_TO;
    // IsoRoom.getRoomDef(), RoomDef.getID(); IsoBuilding.getDef().
    static final MethodHandle ROOM_DEF, ROOM_ID, BUILDING_DEF;
    // IsoObject.getSprite(), getSpriteName(), hasModData(), getModData(); IsoSprite.getName(); KahluaTable.rawget(key).
    static final MethodHandle SPRITE, SPRITE_NAME_OF_OBJECT, HAS_DATA, DATA, SPRITE_NAME, RAWGET;
    // IsoDoor.getNorth(), IsoThumpable.isDoor() and getNorth().
    static final MethodHandle DOOR_NORTH, THUMP_IS_DOOR, THUMP_NORTH;
    // IsoWorld.instance, getMetaGrid(); IsoMetaGrid.getRoomDefByID(id), getZonesAt(x, y, z, list); Zone.getType().
    static final MethodHandle WORLD, META_GRID, ROOM_BY_ID, ZONES_AT, ZONES_INTERSECTING, ZONE_TYPE, ZONE_CONTAINS;
    /** IsoDoor, IsoThumpable, IsoFlagType, IsoRoom, RoomDef, IsoGridSquare. */
    static final Class<?> DOOR, THUMPABLE, FLAG, ROOM_TYPE, ROOM_DEF_TYPE, SQUARE;

    static {
        try {
            var lookup = MethodHandles.publicLookup();
            Class<?> square = SQUARE = Reach.type("zombie.iso.IsoGridSquare"), object = Reach.type("zombie.iso.IsoObject");
            Class<?> room = ROOM_TYPE = Reach.type("zombie.iso.areas.IsoRoom"), def = ROOM_DEF_TYPE = Reach.type("zombie.iso.RoomDef");
            Class<?> building = Reach.type("zombie.iso.areas.IsoBuilding"), sprite = Reach.type("zombie.iso.sprite.IsoSprite");
            Class<?> flag = FLAG = Reach.type("zombie.iso.SpriteDetails.IsoFlagType"), world = Reach.type("zombie.iso.IsoWorld");
            Class<?> grid = Reach.type("zombie.iso.IsoMetaGrid"), zone = Reach.type("zombie.iso.zones.Zone");
            Class<?> table = Reach.type("se.krka.kahlua.vm.KahluaTable");
            DOOR = Reach.type("zombie.iso.objects.IsoDoor");
            THUMPABLE = Reach.type("zombie.iso.objects.IsoThumpable");
            IS_FREE = Reach.handle(lookup, square.getMethod("isFree", boolean.class), MethodType.methodType(boolean.class, Object.class, boolean.class));
            SOLID_FLOOR = Reach.handle(lookup, square.getMethod("TreatAsSolidFloor"), FLAG_OF);
            FLOOR = Reach.handle(lookup, square.getMethod("getFloor"), OBJECT_OF);
            WATER_SQUARE = Reach.handle(lookup, square.getMethod("isWaterSquare"), FLAG_OF);
            OUTSIDE = Reach.handle(lookup, square.getMethod("isOutside"), FLAG_OF);
            STAIRS = Reach.handle(lookup, square.getMethod("HasStairs"), FLAG_OF);
            TREE = Reach.handle(lookup, square.getMethod("HasTree"), FLAG_OF);
            VEHICLE_OVER = Reach.handle(lookup, square.getMethod("isVehicleIntersecting"), FLAG_OF);
            VEHICLE_ON = Reach.handle(lookup, square.getMethod("getVehicleContainer"), OBJECT_OF);
            MOVING = Reach.handle(lookup, square.getMethod("getMovingObjects"), MethodType.methodType(List.class, Object.class));
            OBJECTS = Reach.handle(lookup, square.getMethod("getObjects"), MethodType.methodType(List.class, Object.class));
            CELL = Reach.handle(lookup, square.getMethod("getCell"), OBJECT_OF);
            ROOM = Reach.handle(lookup, square.getMethod("getRoom"), OBJECT_OF);
            BUILDING = Reach.handle(lookup, square.getMethod("getBuilding"), OBJECT_OF);
            HAS_FLAG = Reach.handle(lookup, square.getMethod("has", flag), MethodType.methodType(boolean.class, Object.class, Object.class));
            BLOCKED_TO = Reach.handle(lookup, square.getMethod("isBlockedTo", square), MethodType.methodType(boolean.class, Object.class, Object.class));
            ROOM_DEF = Reach.handle(lookup, room.getMethod("getRoomDef"), OBJECT_OF);
            ROOM_ID = Reach.handle(lookup, def.getMethod("getID"), MethodType.methodType(long.class, Object.class));
            BUILDING_DEF = Reach.handle(lookup, building.getMethod("getDef"), OBJECT_OF);
            SPRITE = Reach.handle(lookup, object.getMethod("getSprite"), OBJECT_OF);
            SPRITE_NAME_OF_OBJECT = Reach.handle(lookup, object.getMethod("getSpriteName"), OBJECT_OF);
            HAS_DATA = Reach.handle(lookup, object.getMethod("hasModData"), FLAG_OF);
            DATA = Reach.handle(lookup, object.getMethod("getModData"), OBJECT_OF);
            SPRITE_NAME = Reach.handle(lookup, sprite.getMethod("getName"), OBJECT_OF);
            RAWGET = Reach.handle(lookup, table.getMethod("rawget", Object.class), MethodType.methodType(Object.class, Object.class, Object.class));
            DOOR_NORTH = Reach.handle(lookup, DOOR.getMethod("getNorth"), FLAG_OF);
            THUMP_IS_DOOR = Reach.handle(lookup, THUMPABLE.getMethod("isDoor"), FLAG_OF);
            THUMP_NORTH = Reach.handle(lookup, THUMPABLE.getMethod("getNorth"), FLAG_OF);
            WORLD = lookup.unreflectGetter(world.getField("instance")).asType(MethodType.methodType(Object.class));
            META_GRID = Reach.handle(lookup, world.getMethod("getMetaGrid"), OBJECT_OF);
            ROOM_BY_ID = Reach.handle(lookup, grid.getMethod("getRoomDefByID", long.class), MethodType.methodType(Object.class, Object.class, long.class));
            ZONES_AT = Reach.handle(lookup, grid.getMethod("getZonesAt", int.class, int.class, int.class, ArrayList.class),
                MethodType.methodType(ArrayList.class, Object.class, int.class, int.class, int.class, ArrayList.class));
            ZONES_INTERSECTING = Reach.handle(lookup, grid.getMethod("getZonesIntersecting", int.class, int.class, int.class, int.class,
                int.class, ArrayList.class), MethodType.methodType(ArrayList.class, Object.class, int.class, int.class, int.class, int.class,
                int.class, ArrayList.class));
            ZONE_TYPE = Reach.handle(lookup, zone.getMethod("getType"), OBJECT_OF);
            ZONE_CONTAINS = Reach.handle(lookup, zone.getMethod("contains", int.class, int.class, int.class),
                MethodType.methodType(boolean.class, Object.class, int.class, int.class, int.class));
        } catch (ReflectiveOperationException failure) {
            throw new ExceptionInInitializerError(failure);
        }
    }

    private SquareFacts() { }

    /** Makes the handles now: a game this cannot read gives a ReflectiveOperationException (as the other areas' lookups do). */
    static void verify() throws ReflectiveOperationException {
        try { IS_FREE.type(); }
        catch (ExceptionInInitializerError | NoClassDefFoundError unreadable) {
            throw new ReflectiveOperationException("the game's squares cannot be asked: " + unreadable,
                unreadable.getCause() != null ? unreadable.getCause() : unreadable);
        }
    }

    /** The meta grid of the world now, or null without a world. */
    static Object metaGrid() throws Throwable {
        Object world = (Object)WORLD.invokeExact();
        return world == null ? null : (Object)META_GRID.invokeExact(world);
    }

    /** The id of the room a square is in, or -1 for none (or for a room the game has no definition of). */
    static long roomIdOf(Object square) throws Throwable {
        Object room = (Object)ROOM.invokeExact(square);
        if (room == null) return -1;
        Object def = (Object)ROOM_DEF.invokeExact(room);
        return def == null ? -1 : (long)ROOM_ID.invokeExact(def);
    }

    /** The name of an object's sprite, or null. */
    static String spriteName(Object object) throws Throwable {
        Object sprite = (Object)SPRITE.invokeExact(object);
        Object name = sprite != null ? (Object)SPRITE_NAME.invokeExact(sprite) : (Object)SPRITE_NAME_OF_OBJECT.invokeExact(object);
        return name instanceof String text ? text : null;
    }
}
