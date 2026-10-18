// STUB: replaced by perf/squares and perf/items at merge
package pzext.api;

/** A condition on a square (docs/design.md, "Conditions on a square"). The stub reads room, building, free, outside and water only. */
final class SquareFilter {
    private final Game game;
    private final Boolean free, outside, water;
    private final Object room, building;
    private final java.lang.reflect.Method isFree, isOutside, isWater;

    private SquareFilter(Game game, Boolean free, Boolean outside, Boolean water, Object room, Object building, Class<?> square)
            throws ReflectiveOperationException {
        this.game = game;
        this.free = free; this.outside = outside; this.water = water; this.room = room; this.building = building;
        isFree = square.getMethod("isFree", boolean.class);
        isOutside = square.getMethod("isOutside");
        isWater = square.getMethod("isWaterSquare");
    }

    static SquareFilter read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        ClassLoader loader = game.objectType.getClassLoader();
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare");
        if (table == null) return new SquareFilter(game, null, null, null, null, null, square);
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": a filter must be a table");
        Object room = lua.get(table, "room"), building = lua.get(table, "building");
        if (room != null && !(room instanceof String text && (text.equals("none") || text.equals("any")))) {
            RoomRefs refs = new RoomRefs(game, loader);
            if (!refs.isRoom(room)) throw new IllegalArgumentException(call + ": room must be \"none\", \"any\" or a room");
            room = refs.resolve(room);
        }
        return new SquareFilter(game, bool(lua, table, "free"), bool(lua, table, "outside"), bool(lua, table, "water"), room, building, square);
    }

    private static Boolean bool(Kahlua lua, Object table, String key) throws ReflectiveOperationException {
        return lua.get(table, key) instanceof Boolean value ? value : null;
    }

    boolean test(Object square) throws Throwable {
        if (free != null && (boolean)isFree.invoke(square, false) != free) return false;
        if (outside != null && (boolean)isOutside.invoke(square) != outside) return false;
        if (water != null && (boolean)isWater.invoke(square) != water) return false;
        if (room == null && building == null) return true;
        Buildings buildings = GameApi.buildings();
        int x = game.x(square), y = game.y(square), z = game.z(square);
        if (room != null) {
            Object there = buildings.roomOf(x, y, z);
            if ("none".equals(room) ? there != null : "any".equals(room) ? there == null : there != room) return false;
        }
        if (building != null) {
            Buildings.Building there = buildings.buildingAt(x, y, z);
            if ("none".equals(building) ? there != null : "any".equals(building) ? there == null : there == null || !there.key().equals(building)) return false;
        }
        return true;
    }
}
