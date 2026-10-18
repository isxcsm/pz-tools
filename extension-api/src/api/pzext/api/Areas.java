package pzext.api;

import java.util.List;
import java.util.Map;

/**
 * Where a query looks (docs/design.md, "Areas"): a box, a disc, rings round a point, a room, a building's rooms, or a list of
 * squares. An area is read from its table when a call starts and walked once; squares are fetched from the cell as the walk
 * reaches them (nothing is listed first), through method handles, and nothing is allocated for a square. Rings are walked by their
 * perimeter, a disc by the span of each of its rows.
 */
final class Areas {
    /** The most squares one walk looks at (loaded or not); more is an error that says so. */
    static final int MAX_SQUARES = 250_000;
    static final int MAX_COORDINATE = 8_388_607, MIN_LEVEL = -32, MAX_LEVEL = 31;

    private Areas() { }

    /** What a walk does with a loaded square; false stops it. */
    @FunctionalInterface interface Visit { boolean square(Object square, int x, int y, int z) throws Throwable; }

    /**
     * What a walk does with each place of the area, loaded or not: {@code square} is null where none is loaded; {@code index} counts
     * the places from 1 (for a list, its position in the list); {@code ring} is the ring's distance for rings, else -1.
     */
    @FunctionalInterface interface Scan { boolean at(Object square, int x, int y, int z, int index, int ring) throws Throwable; }

    interface Area {
        /** The loaded squares, in the area's order; throws IllegalArgumentException past {@link #MAX_SQUARES} squares looked at. */
        void each(Visit visit) throws Throwable;

        /** Every place of the area in its order, the loaded ones with their square; the same limit. */
        void scan(Scan scan) throws Throwable;

        /** Whether the area is made of rings, whose ring a walk tells. */
        default boolean rings() { return false; }
    }

    /** The area a table says. A wrong table is an IllegalArgumentException that names {@code call}. */
    static Area read(Kahlua lua, Game game, Object table, String call) throws ReflectiveOperationException {
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": area must be a table");
        try {
            Area made = area(lua, game, table, call);
            ((Base)made).call = call;
            return made;
        }
        catch (RuntimeException | Error | ReflectiveOperationException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    private static Area area(Kahlua lua, Game game, Object table, String call) throws Throwable {
        Object cell = game.cell();
        if (lua.get(table, "list") != null) {
            only(lua, table, call, "list");
            Object list = lua.get(table, "list");
            if (!lua.isTable(list)) throw new IllegalArgumentException(call + ": area.list must be a list x1, y1, z1, x2, y2, z2, ...");
            int length = lua.length(list);
            if (length % 3 != 0) throw new IllegalArgumentException(call + ": area.list must be a list x1, y1, z1, x2, y2, z2, ...");
            return new Listed(lua, cell, list, length / 3, call);
        }
        if (lua.get(table, "room") != null) {
            only(lua, table, call, "room");
            return new Rooms(cell, roomRects(game, SquareFilter.roomId(lua.get(table, "room"), call, "area.room"), call));
        }
        if (lua.get(table, "building") != null) {
            only(lua, table, call, "building", "z");
            if (!(lua.get(table, "building") instanceof String key)) throw new IllegalArgumentException(call + ": area.building must be a building key");
            Object level = lua.get(table, "z");
            int z = level == null ? Integer.MIN_VALUE : whole(level, call, "area.z", MIN_LEVEL, MAX_LEVEL);
            return new Rooms(cell, buildingRects(key, z, call));
        }
        if (lua.get(table, "x1") != null) {
            only(lua, table, call, "x1", "y1", "x2", "y2", "z");
            int x1 = coordinate(lua, table, "x1", call), x2 = coordinate(lua, table, "x2", call);
            int y1 = coordinate(lua, table, "y1", call), y2 = coordinate(lua, table, "y2", call);
            int z = whole(lua.get(table, "z"), call, "area.z", MIN_LEVEL, MAX_LEVEL);
            return new Box(cell, Math.min(x1, x2), Math.min(y1, y2), Math.max(x1, x2), Math.max(y1, y2), z);
        }
        if (lua.get(table, "r") != null) {
            only(lua, table, call, "x", "y", "z", "r");
            double x = SquareFilter.number(lua.get(table, "x"), call, "area.x"), y = SquareFilter.number(lua.get(table, "y"), call, "area.y");
            double r = SquareFilter.number(lua.get(table, "r"), call, "area.r");
            if (r < 0 || r > MAX_COORDINATE || Math.abs(x) > MAX_COORDINATE || Math.abs(y) > MAX_COORDINATE)
                throw new IllegalArgumentException(call + ": area.r must be a number from 0, and x and y within the map");
            return new Disc(cell, x, y, whole(lua.get(table, "z"), call, "area.z", MIN_LEVEL, MAX_LEVEL), r);
        }
        if (lua.get(table, "to") != null) {
            only(lua, table, call, "x", "y", "z", "from", "to", "step");
            int x = coordinate(lua, table, "x", call), y = coordinate(lua, table, "y", call);
            int z = whole(lua.get(table, "z"), call, "area.z", MIN_LEVEL, MAX_LEVEL);
            int from = lua.get(table, "from") == null ? 0 : whole(lua.get(table, "from"), call, "area.from", 0, MAX_COORDINATE);
            int to = whole(lua.get(table, "to"), call, "area.to", 0, MAX_COORDINATE);
            int step = lua.get(table, "step") == null ? 1 : whole(lua.get(table, "step"), call, "area.step", 1, MAX_COORDINATE);
            return new RingsOf(cell, x, y, z, from, to, step);
        }
        throw new IllegalArgumentException(call + ": area must have x1, y1, x2, y2 and z (a box); x, y, z and r (a disc); x, y, z and to (rings); room; building; or list");
    }

    private static void only(Kahlua lua, Object table, String call, String... allowed) throws ReflectiveOperationException {
        outer:
        for (Map.Entry<Object, Object> entry : lua.entries(table)) {
            for (String name : allowed) if (name.equals(entry.getKey())) continue outer;
            throw new IllegalArgumentException(call + ": area." + entry.getKey() + " does not go with this form of area");
        }
    }

    private static int coordinate(Kahlua lua, Object table, String name, String call) {
        try { return whole(lua.get(table, name), call, "area.", name, -MAX_COORDINATE, MAX_COORDINATE); }
        catch (ReflectiveOperationException unreadable) { throw new IllegalStateException(unreadable); }
    }

    static int whole(Object value, String call, String name, int min, int max) {
        if (!(value instanceof Double number) || number != Math.rint(number) || number < min || number > max)
            throw new IllegalArgumentException(call + ": " + name + " must be a whole number from " + min + " to " + max);
        return number.intValue();
    }

    /** As above, for the value {@code prefix + name}: that name is made only when the value is wrong. */
    static int whole(Object value, String call, String prefix, String name, int min, int max) {
        if (value instanceof Double number && number == Math.rint(number) && number >= min && number <= max) return number.intValue();
        return whole(value, call, prefix + name, min, max);
    }

    /** As above, for the value {@code prefix + index + suffix}. */
    static int whole(Object value, String call, String prefix, int index, String suffix, int min, int max) {
        if (value instanceof Double number && number == Math.rint(number) && number >= min && number <= max) return number.intValue();
        return whole(value, call, prefix + index + suffix, min, max);
    }

    private static IllegalArgumentException tooMany(String call) {
        return new IllegalArgumentException(call + ": the area has more than " + MAX_SQUARES + " squares to look at; narrow it");
    }

    /** What every area shares: the cell, the call's counting of squares looked at, and {@code each} as a scan of loaded ones. */
    private abstract static class Base implements Area {
        final Object cell;
        String call = "area";
        private int looked;

        Base(Object cell) { this.cell = cell; }

        @Override public final void each(Visit visit) throws Throwable {
            scan((square, x, y, z, index, ring) -> square == null || visit.square(square, x, y, z));
        }

        @Override public final void scan(Scan scan) throws Throwable {
            if (cell == null) return;
            looked = 0;
            walk(scan);
        }

        abstract void walk(Scan scan) throws Throwable;

        /** The place x, y, z is looked at: the walk goes on while the scan says so. */
        final boolean look(Scan scan, int x, int y, int z, int ring) throws Throwable {
            if (++looked > MAX_SQUARES) throw tooMany(call);
            Object square = (Object)Reach.GRID_SQUARE.invokeExact(cell, x, y, z);
            return scan.at(square, x, y, z, looked, ring);
        }
    }

    private static final class Box extends Base {
        private final int x1, y1, x2, y2, z;

        Box(Object cell, int x1, int y1, int x2, int y2, int z) { super(cell); this.x1 = x1; this.y1 = y1; this.x2 = x2; this.y2 = y2; this.z = z; }

        @Override void walk(Scan scan) throws Throwable {
            for (int y = y1; y <= y2; y++) for (int x = x1; x <= x2; x++) if (!look(scan, x, y, z, -1)) return;
        }
    }

    private static final class Disc extends Base {
        private final double px, py, r, r2;
        private final int z;

        Disc(Object cell, double px, double py, int z, double r) { super(cell); this.px = px; this.py = py; this.z = z; this.r = r; r2 = r * r; }

        private boolean in(int x, int y) { double dx = x - px, dy = y - py; return dx * dx + dy * dy <= r2; }

        @Override void walk(Scan scan) throws Throwable {
            int top = (int)Math.ceil(py - r), bottom = (int)Math.floor(py + r);
            for (int y = top; y <= bottom; y++) {
                double dy = y - py, span = Math.sqrt(Math.max(0, r2 - dy * dy));
                int from = (int)Math.ceil(px - span), to = (int)Math.floor(px + span);
                // The span is worked out in floating point: settled square by square at its ends.
                while (in(from - 1, y)) from--;
                while (from <= to && !in(from, y)) from++;
                while (in(to + 1, y)) to++;
                while (to >= from && !in(to, y)) to--;
                for (int x = from; x <= to; x++) if (!look(scan, x, y, z, -1)) return;
            }
        }
    }

    private static final class RingsOf extends Base {
        private final int cx, cy, z, from, to, step;

        RingsOf(Object cell, int cx, int cy, int z, int from, int to, int step) {
            super(cell); this.cx = cx; this.cy = cy; this.z = z; this.from = from; this.to = to; this.step = step;
        }

        @Override public boolean rings() { return true; }

        @Override void walk(Scan scan) throws Throwable {
            for (long r = from; r <= to; r += step) {
                int ring = (int)r;
                if (ring == 0) { if (!look(scan, cx, cy, z, 0)) return; continue; }
                // The perimeter: the top row, the right column below it, the bottom row back, the left column up.
                for (int x = cx - ring; x <= cx + ring; x++) if (!look(scan, x, cy - ring, z, ring)) return;
                for (int y = cy - ring + 1; y <= cy + ring; y++) if (!look(scan, cx + ring, y, z, ring)) return;
                for (int x = cx + ring - 1; x >= cx - ring; x--) if (!look(scan, x, cy + ring, z, ring)) return;
                for (int y = cy + ring - 1; y > cy - ring; y--) if (!look(scan, cx - ring, y, z, ring)) return;
            }
        }
    }

    /** A list of squares x1, y1, z1, ...: read from the Lua table as the walk reaches them, not copied. */
    private static final class Listed extends Base {
        private final Kahlua lua;
        private final Object list;
        private final int count;
        private final String call;

        Listed(Kahlua lua, Object cell, Object list, int count, String call) {
            super(cell); this.lua = lua; this.list = list; this.count = count; this.call = call;
        }

        private int at(int position, int min, int max) throws Throwable {
            return whole(lua.at(list, position), call, "area.list[", position, "]", min, max);
        }

        @Override void walk(Scan scan) throws Throwable {
            for (int entry = 0; entry < count; entry++) {
                int x = at(entry * 3 + 1, -MAX_COORDINATE, MAX_COORDINATE), y = at(entry * 3 + 2, -MAX_COORDINATE, MAX_COORDINATE);
                int z = at(entry * 3 + 3, MIN_LEVEL, MAX_LEVEL);
                if (!look(scan, x, y, z, -1)) return;
            }
        }
    }

    /** The squares of rectangles of one level each, in the order given. */
    private static final class Rooms extends Base {
        private final List<int[]> rects; // x, y, w, h, level

        Rooms(Object cell, List<int[]> rects) { super(cell); this.rects = rects; }

        @Override void walk(Scan scan) throws Throwable {
            for (int[] rect : rects)
                for (int y = rect[1]; y < rect[1] + rect[3]; y++) for (int x = rect[0]; x < rect[0] + rect[2]; x++) if (!look(scan, x, y, rect[4], -1)) return;
        }
    }

    private static List<int[]> roomRects(Game game, long id, String call) throws Throwable {
        Buildings buildings = GameApi.buildings();
        if (buildings == null) throw new IllegalArgumentException(call + ": the buildings are not available in this game");
        Object grid = SquareFacts.metaGrid();
        Object room = grid == null ? null : (Object)SquareFacts.ROOM_BY_ID.invokeExact(grid, id);
        var result = new java.util.ArrayList<int[]>();
        if (room != null) addRects(buildings, room, result);
        return result;
    }

    private static void addRects(Buildings buildings, Object room, List<int[]> into) throws ReflectiveOperationException {
        int level = buildings.level(room);
        for (Buildings.Rect rect : buildings.rects(room)) into.add(new int[] { rect.x(), rect.y(), rect.w(), rect.h(), level });
    }

    private static List<int[]> buildingRects(String key, int level, String call) throws Throwable {
        Buildings buildings = GameApi.buildings();
        if (buildings == null) throw new IllegalArgumentException(call + ": the buildings are not available in this game");
        Buildings.Building found = buildings.resolve(key);
        var result = new java.util.ArrayList<int[]>();
        if (found != null)
            for (Object room : found.rooms()) if (level == Integer.MIN_VALUE || buildings.level(room) == level) addRects(buildings, room, result);
        return result;
    }
}
