// STUB: replaced by perf/squares and perf/items at merge
package pzext.api;

/** Where a query looks (docs/design.md, "Areas"). The stub reads a box, a circle, a room and a list. */
final class Areas {
    private Areas() { }

    /** Called for each loaded square of an area; false stops. */
    @FunctionalInterface interface Visit { boolean square(Object square, int x, int y, int z) throws Throwable; }

    /** The loaded squares of a place, in its order. */
    interface Area { void each(Visit visit) throws Throwable; }

    static Area read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": area must be a table");
        Object cells = game.cell();
        if (lua.get(table, "x1") != null) {
            int x1 = whole(lua, table, "x1", call), y1 = whole(lua, table, "y1", call), x2 = whole(lua, table, "x2", call);
            int y2 = whole(lua, table, "y2", call), z = whole(lua, table, "z", call);
            return visit -> {
                for (int y = y1; y <= y2; y++)
                    for (int x = x1; x <= x2; x++) {
                        Object square = game.square(cells, x, y, z);
                        if (square != null && !visit.square(square, x, y, z)) return;
                    }
            };
        }
        if (lua.get(table, "r") != null) {
            int cx = whole(lua, table, "x", call), cy = whole(lua, table, "y", call), z = whole(lua, table, "z", call);
            double r = (Double)lua.get(table, "r");
            int reach = (int)Math.ceil(r);
            return visit -> {
                for (int y = cy - reach; y <= cy + reach; y++)
                    for (int x = cx - reach; x <= cx + reach; x++) {
                        if (Math.hypot(x - cx, y - cy) > r) continue;
                        Object square = game.square(cells, x, y, z);
                        if (square != null && !visit.square(square, x, y, z)) return;
                    }
            };
        }
        if (lua.get(table, "room") != null) {
            var refs = new RoomRefs(game, game.objectType.getClassLoader());
            Object room = refs.resolve(lua.get(table, "room"));
            if (room == null) throw new IllegalArgumentException(call + ": area.room names no room");
            Buildings buildings = GameApi.buildings();
            int z = buildings.level(room);
            var rects = buildings.rects(room);
            return visit -> {
                for (Buildings.Rect rect : rects)
                    for (int y = rect.y(); y < rect.y() + rect.h(); y++)
                        for (int x = rect.x(); x < rect.x() + rect.w(); x++) {
                            Object square = game.square(cells, x, y, z);
                            if (square != null && !visit.square(square, x, y, z)) return;
                        }
            };
        }
        if (lua.isTable(lua.get(table, "list"))) {
            Object list = lua.get(table, "list");
            int length;
            try { length = lua.length(list); } catch (Throwable failure) { throw Game.thrown(failure); }
            if (length % 3 != 0) throw new IllegalArgumentException(call + ": area.list must be x1, y1, z1, x2, ...");
            return visit -> {
                for (int at = 1; at <= length; at += 3) {
                    int x = ((Double)lua.at(list, at)).intValue(), y = ((Double)lua.at(list, at + 1)).intValue(), z = ((Double)lua.at(list, at + 2)).intValue();
                    Object square = game.square(cells, x, y, z);
                    if (square != null && !visit.square(square, x, y, z)) return;
                }
            };
        }
        throw new IllegalArgumentException(call + ": area is not one of the forms");
    }

    private static int whole(Kahlua lua, Object table, String key, String call) throws ReflectiveOperationException {
        if (!(lua.get(table, key) instanceof Double number) || number != Math.rint(number))
            throw new IllegalArgumentException(call + ": area." + key + " must be a whole number");
        return number.intValue();
    }
}
