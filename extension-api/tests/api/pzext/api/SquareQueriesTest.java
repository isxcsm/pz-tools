package pzext.api;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.BiPredicate;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.iso.BuildingDef;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.iso.areas.IsoBuilding;
import zombie.iso.areas.IsoRoom;
import zombie.iso.objects.IsoDoor;
import zombie.iso.objects.IsoThumpable;
import zombie.iso.sprite.IsoSprite;
import zombie.iso.zones.Zone;
import zombie.vehicles.BaseVehicle;

/**
 * {@code squares.nearest}, {@code list} and {@code fit} with the conditions and areas they take (docs/design.md, "World queries"),
 * against the synthetic game: every condition, every form of area, the options of list and fit, the errors a mod is told, a filter
 * read once and kept with its table, the functions of a replaced API refusing to be called, and what the walks cost.
 */
final class SquareQueriesTest {
    private static final ClassLoader GAME = SquareQueriesTest.class.getClassLoader();
    // A 10 by 10 grid of loaded squares.
    private static final int X0 = 100, Y0 = 100, SIZE = 10;

    private static KahluaTable API;

    private SquareQueriesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        try {
            API = api;
            var area = (KahluaTable)api.rawget("squares");
            check(area != null && area.rawget("nearest") != null && area.rawget("list") != null && area.rawget("fit") != null
                && area.rawget("watch") != null, "PZExtAPI.squares lacks the queries or the watches");
            conditions(area);
            oneSquare(area);
            doorEdges(area);
            around(area);
            areas(area);
            nearest(area);
            lists(area);
            fits(area);
            try { caching(); }
            catch (Exception | Error failure) { throw failure; }
            catch (Throwable failure) { throw new AssertionError(failure); }
            fitLimit(area);
            errors(area);
            takeover(api);
            cost(api);
        } finally {
            IsoWorld.instance.setCell(home);
            IsoWorld.instance.metaGrid.zones.clear();
        }
    }

    // ---- building tables and reading answers ----

    private static Object value(Object any) { return any instanceof Integer number ? (Object)(double)number : any; }

    /** A Lua table of key, value, key, value, ... (whole numbers become Lua numbers). */
    private static KahluaTable table(Object... pairs) {
        var result = new KahluaTableImpl();
        for (int at = 0; at < pairs.length; at += 2) result.rawset(pairs[at], value(pairs[at + 1]));
        return result;
    }

    /** A Lua list of the values. */
    private static KahluaTable list(Object... values) {
        var result = new KahluaTableImpl();
        for (int at = 0; at < values.length; at++) result.rawset(at + 1, value(values[at]));
        return result;
    }

    private static KahluaTable box(int x1, int y1, int x2, int y2) { return table("x1", x1, "y1", y1, "x2", x2, "y2", y2, "z", 0); }

    private static KahluaTable whole() { return box(X0, Y0, X0 + SIZE - 1, Y0 + SIZE - 1); }

    private static IsoCell grid() {
        var cell = new IsoCell();
        IsoWorld.instance.setCell(cell);
        for (int y = Y0; y < Y0 + SIZE; y++) for (int x = X0; x < X0 + SIZE; x++) cell.load(x, y, 0).outdoors = false;
        return cell;
    }

    private static IsoGridSquare at(int x, int y) { return IsoWorld.instance.currentCell.getGridSquare(x, y, 0); }

    private static String name(Object square) { var s = (IsoGridSquare)square; return s.x + "," + s.y; }

    /** The squares of a list answer, as "x,y" in the order given. */
    private static List<String> names(Object answer) {
        var result = new ArrayList<String>();
        var squares = (KahluaTable)answer;
        for (int at = 1; at <= squares.len(); at++) result.add(name(squares.rawget(at)));
        return result;
    }

    private static List<String> walk(KahluaTable area, KahluaTable where, KahluaTable filter) {
        return names(FormulasTest.call(area, "list", where, filter).get(0));
    }

    private static Set<String> hits(KahluaTable area, KahluaTable filter) { return new TreeSet<>(walk(area, whole(), filter)); }

    /** The squares of the grid that meet a test of their place, as "x,y". */
    private static Set<String> where(BiPredicate<Integer, Integer> test) {
        var result = new TreeSet<String>();
        for (int y = Y0; y < Y0 + SIZE; y++) for (int x = X0; x < X0 + SIZE; x++) if (test.test(x, y)) result.add(x + "," + y);
        return result;
    }

    private static Set<String> set(String... squares) { return new TreeSet<>(List.of(squares)); }

    private static Set<String> except(Set<String> all, String... out) {
        var result = new TreeSet<>(all);
        for (String square : out) result.remove(square);
        return result;
    }

    private static void same(Set<String> expected, Set<String> actual, String what) {
        check(expected.equals(actual), what + ": expected " + expected + ", got " + actual);
    }

    private static final Set<String> ALL = where((x, y) -> true);

    // ---- the conditions ----

    private static void conditions(KahluaTable area) {
        grid();
        check(hits(area, null).equals(ALL) && hits(area, table()).equals(ALL), "A nil or empty filter did not pass every loaded square");
        at(101, 100).freeOfObjects = false;
        same(except(ALL, "101,100"), hits(area, table("free", true)), "free = true");
        same(set("101,100"), hits(area, table("free", false)), "free = false");
        at(102, 100).solidFloorTreated = false;
        same(set("102,100"), hits(area, table("solidFloor", false)), "solidFloor = false");
        same(except(ALL, "102,100"), hits(area, table("solidFloor", true)), "solidFloor = true");

        for (int y = Y0; y < Y0 + SIZE; y++) for (int x = X0; x < X0 + SIZE; x++) at(x, y).floor = new IsoObject(new IsoSprite("blends_natural_01_0"));
        at(103, 100).floor = null;
        at(104, 100).floor = new IsoObject(new IsoSprite("floors_exterior_street_01_1"));
        same(set("103,100"), hits(area, table("floor", false)), "floor = false");
        same(except(ALL, "103,100"), hits(area, table("floor", true)), "floor = true");
        same(except(ALL, "103,100", "104,100"), hits(area, table("floorPrefix", list("blends_natural", "other"))), "floorPrefix");
        same(set("104,100"), hits(area, table("floorPrefix", list("floors_ext"))), "floorPrefix on the other floor");
        same(except(ALL, "104,100"), hits(area, table("floorAvoid", list("street", "water"))), "floorAvoid (no floor: met)");

        at(105, 100).waterSquare = true;
        at(106, 100).flagSet.add(IsoFlagType.water);
        same(set("105,100"), hits(area, table("water", true)), "water");
        same(set("106,100"), hits(area, table("waterFlag", true)), "waterFlag");
        same(except(ALL, "106,100"), hits(area, table("waterFlag", false)), "waterFlag = false");
        same(set("105,100", "106,100"), hits(area, table("wet", true)), "wet: either way of telling water");
        same(except(ALL, "105,100", "106,100"), hits(area, table("wet", false)), "wet = false");
        at(107, 100).outdoors = true;
        same(set("107,100"), hits(area, table("outside", true)), "outside");
        at(108, 100).stairs = true;
        at(109, 100).tree = true;
        same(set("108,100"), hits(area, table("stairs", true)), "stairs");
        same(set("109,100"), hits(area, table("tree", true)), "tree");

        at(100, 101).vehicleOver = true;
        at(101, 101).vehicleOn = new BaseVehicle();
        same(except(ALL, "100,101", "101,101"), hits(area, table("vehicle", false)), "vehicle = false");
        same(set("100,101", "101,101"), hits(area, table("vehicle", true)), "vehicle = true");
        at(102, 101).movers.add(new IsoMovingObject());
        same(except(ALL, "102,101"), hits(area, table("moving", false)), "moving = false");

        at(103, 101).flagSet.add(IsoFlagType.burntOut);
        at(104, 101).flagSet.add(IsoFlagType.burntOut);
        at(104, 101).flagSet.add(IsoFlagType.burning);
        same(set("103,101", "104,101"), hits(area, table("flags", list("burntOut"))), "flags");
        same(set("104,101"), hits(area, table("flags", list("burntOut", "burning"))), "flags needs all");
        same(except(ALL, "103,101", "104,101"), hits(area, table("noFlags", list("burntOut", "burning"))), "noFlags");

        var marked = new IsoObject(new IsoSprite("crate"));
        marked.getModData().rawset("mark", true);
        at(105, 101).objects.add(marked);
        at(106, 101).objects.add(new IsoObject(new IsoSprite("plain")));
        same(except(ALL, "105,101"), hits(area, table("noObjectData", "mark")), "noObjectData");

        var zones = IsoWorld.instance.metaGrid.zones;
        zones.add(new Zone("", "Forest", 107, 101, 0, 2, 1));
        zones.add(new Zone("", "Farm", 108, 101, 0, 1, 1));
        zones.add(new Zone("", "Forest", 100, 102, 1, 3, 1));
        same(except(ALL, "107,101", "108,101"), hits(area, table("zonesNot", list("Forest"))), "zonesNot (one level only)");
        same(except(ALL, "108,101"), hits(area, table("zonesNot", list("Farm"))), "zonesNot Farm");
        same(except(ALL, "107,101", "108,101"), hits(area, table("zonesNot", list("Farm", "Forest"))), "zonesNot either");
        zones.clear();

        // a road one square wide along x = 110: none within 2, one within 6 (or 4)
        zones.add(new Zone("", "Nav", 110, 90, 0, 1, 30));
        same(where((x, y) -> x >= 104 && x <= 107), hits(area, table("zoneNear", table("type", "Nav", "none", 2, "some", 6))),
            "zoneNear: a road in sight, not within none");
        same(where((x, y) -> x >= 106 && x <= 107), hits(area, table("zoneNear", table("type", "Nav", "none", 2, "some", 4))),
            "zoneNear: some is the edge");
        same(where((x, y) -> x <= 107), hits(area, table("zoneNear", table("type", "Nav", "none", 2))), "zoneNear: none alone");
        same(ALL, hits(area, table("zoneNear", table("type", "Farm", "none", 3))), "zoneNear: no zone of the type");
        zones.clear();

        var inRoom = new IsoRoom(100, 103, 2, 1);
        inRoom.def = new RoomDef(9001, "den");
        at(100, 103).room = inRoom;
        at(101, 103).room = inRoom;
        var other = new IsoRoom(102, 103, 1, 1);
        other.def = new RoomDef(9002, "hall");
        at(102, 103).room = other;
        same(set("100,103", "101,103", "102,103"), hits(area, table("room", "any")), "room = any");
        same(except(ALL, "100,103", "101,103", "102,103"), hits(area, table("room", "none")), "room = none");
        same(set("100,103", "101,103"), hits(area, table("room", inRoom)), "room as an IsoRoom");
        same(set("100,103", "101,103"), hits(area, table("room", inRoom.def)), "room as a RoomDef");
        same(set("102,103"), hits(area, table("room", "9002")), "room as its id");
        same(set(), hits(area, table("room", "9003")), "room of an id nobody has");

        var def = new BuildingDef(false);
        var rooms = IsoWorld.instance.metaGrid.rooms;
        var shed = new RoomDef(9100, "shed", 0, def);
        shed.rects.add(new RoomDef.RoomRect(103, 103, 2, 1));
        rooms.add(shed);
        try {
            var built = new IsoBuilding(def);
            at(103, 103).building = built;
            at(104, 103).building = built;
            at(105, 103).building = new IsoBuilding(new BuildingDef(false));
            same(set("103,103", "104,103", "105,103"), hits(area, table("building", "any")), "building = any");
            same(except(ALL, "103,103", "104,103", "105,103"), hits(area, table("building", "none")), "building = none");
            String key = (String)((KahluaTable)FormulasTest.call((KahluaTable)API.rawget("buildings"), "at", 103.0, 103.0, 0.0).get(0)).rawget("key");
            same(set("103,103", "104,103"), hits(area, table("building", key)), "building by its key");
            same(set(), hits(area, table("building", "1,1,0")), "building by a key nobody has");
        } finally { rooms.remove(shed); }

        // Several conditions must all be met.
        same(set("101,100"), hits(area, table("free", false, "floorPrefix", list("blends"))), "two conditions");
        same(set("104,100"), hits(area, table("floorPrefix", list("floors"), "solidFloor", true, "free", true)), "three conditions");

        // distance: from the point to the square's place.
        grid();
        same(where((x, y) -> (x - 100) * (x - 100) + (y - 100) * (y - 100) <= 4), hits(area, table("distance", table("x", 100, "y", 100, "max", 2))), "distance max");
        same(where((x, y) -> (x - 100) * (x - 100) + (y - 100) * (y - 100) >= 144), hits(area, table("distance", table("x", 100, "y", 100, "min", 12))), "distance min");
        same(where((x, y) -> { int d = (x - 103) * (x - 103) + (y - 103) * (y - 103); return d >= 4 && d <= 9; }),
            hits(area, table("distance", table("x", 103, "y", 103, "min", 2, "max", 3))), "distance min and max");

        // clear: every square within r is loaded and meets the filter; an unloaded square fails it.
        grid();
        at(105, 105).freeOfObjects = false;
        same(where((x, y) -> x > X0 && x < X0 + SIZE - 1 && y > Y0 && y < Y0 + SIZE - 1 && (Math.abs(x - 105) > 1 || Math.abs(y - 105) > 1)),
            hits(area, table("clear", table("r", 1, "filter", table("free", true)))), "clear r = 1");
        same(where((x, y) -> x > X0 && x < X0 + SIZE - 1 && y > Y0 && y < Y0 + SIZE - 1), hits(area, table("clear", table("r", 1))), "clear without a filter needs loaded squares");
        same(ALL, hits(area, table("clear", table("r", 0))), "clear r = 0");
        same(set("105,105"), hits(area, table("clear", table("r", 0, "filter", table("free", false)))), "clear r = 0 with a filter");
    }

    /** test and why: one square against a filter; why names the first condition it fails, in the game's order. */
    private static void oneSquare(KahluaTable area) {
        // natural: the game's digging rule (floors_exterior_natural, blends_natural_01); no floor is not ground
        grid();
        for (int y = Y0; y < Y0 + SIZE; y++) for (int x = X0; x < X0 + SIZE; x++) at(x, y).floor = new IsoObject(new IsoSprite("blends_natural_01_0"));
        at(101, 100).floor = new IsoObject(new IsoSprite("floors_exterior_natural_01_12"));
        at(102, 100).floor = new IsoObject(new IsoSprite("blends_natural_02_0"));
        at(103, 100).floor = new IsoObject(new IsoSprite("floors_exterior_street_01_1"));
        at(104, 100).floor = null;
        same(except(ALL, "102,100", "103,100", "104,100"), hits(area, table("natural", true)), "natural");
        same(set("102,100", "103,100", "104,100"), hits(area, table("natural", false)), "natural = false");
        grid();
        var place = table("free", true, "wet", false, "vehicle", false, "solidFloor", true, "noObjectData", "mark");
        check(Boolean.TRUE.equals(FormulasTest.call(area, "test", at(100, 100), place).get(0)), "test: a plain square meets the filter");
        check(FormulasTest.call(area, "why", at(100, 100), place).get(0) == null, "why: nil for a square that meets it");
        at(101, 100).waterSquare = true;
        at(101, 100).freeOfObjects = false;
        check(Boolean.FALSE.equals(FormulasTest.call(area, "test", at(101, 100), place).get(0)), "test: water fails");
        check("wet".equals(FormulasTest.call(area, "why", at(101, 100), place).get(0)), "why: water before blocked");
        at(102, 100).solidFloorTreated = false;
        at(102, 100).vehicleOver = true;
        check("solidFloor".equals(FormulasTest.call(area, "why", at(102, 100), place).get(0)), "why: no floor before a vehicle");
        at(103, 100).vehicleOver = true;
        at(103, 100).freeOfObjects = false;
        check("vehicle".equals(FormulasTest.call(area, "why", at(103, 100), place).get(0)), "why: a vehicle before blocked");
        var marked = new IsoObject(new IsoSprite("crate"));
        marked.getModData().rawset("mark", true);
        at(104, 100).objects.add(marked);
        check("noObjectData".equals(FormulasTest.call(area, "why", at(104, 100), place).get(0)), "why: taken");
        error(area, "test", "square must be a loaded square", 1.0, place);
        error(area, "why", "square must be a loaded square", null, place);
    }

    /** doorEdge = false: no door or doorway on any of the four edges (the square's north and west, the south square's north, the east square's west). */
    private static void doorEdges(KahluaTable area) {
        grid();
        at(102, 102).northDoor = true;
        add(at(105, 105), door(false));
        add(at(107, 107), thumpable(true, true));
        add(at(108, 108), thumpable(false, true));
        add(at(101, 104), door(true));
        at(109, 102).westDoor = true;
        Set<String> doors = set("102,102", "102,101", "105,105", "104,105", "107,107", "107,106", "108,108", "107,108", "101,104", "101,103", "109,102", "108,102");
        // A thumpable that is no door is no door.
        add(at(106, 100), thumpable(true, false));
        same(except(ALL, doors.toArray(new String[0])), hits(area, table("doorEdge", false)), "doorEdge = false");
        same(doors, hits(area, table("doorEdge", true)), "doorEdge = true");
        // A door on the south square's west edge, or the east square's north edge, is not on this square's edges.
        grid();
        add(at(103, 104), door(false));
        same(set("103,104", "102,104"), hits(area, table("doorEdge", true)), "a west door touches its own square and the one west of it");
        grid();
        add(at(103, 104), door(true));
        same(set("103,104", "103,103"), hits(area, table("doorEdge", true)), "a north door touches its own square and the one north of it");
        // On the edge of the loaded squares: the neighbour beyond is not loaded, which is no door.
        grid();
        add(at(109, 109), door(false));
        same(set("109,109", "108,109"), hits(area, table("doorEdge", true)), "a door at the edge of the loaded squares");
    }

    private static IsoDoor door(boolean north) { var door = new IsoDoor(new IsoSprite("door")); door.north = north; return door; }

    private static IsoThumpable thumpable(boolean north, boolean isDoor) {
        var built = new IsoThumpable(new IsoSprite("built"));
        built.north = north;
        built.setIsDoor(isDoor);
        return built;
    }

    private static void add(IsoGridSquare square, IsoObject object) { object.square = square; square.objects.add(object); }

    private static void around(KahluaTable area) {
        grid();
        at(105, 105).tree = true;
        same(where((x, y) -> Math.abs(x - 105) <= 1 && Math.abs(y - 105) <= 1 && (x != 105 || y != 105)),
            hits(area, table("around", table("tree", true))), "around: the 8 squares, not the square itself");
        at(100, 100).tree = true;
        same(set("101,100", "100,101", "101,101", "104,104", "105,104", "106,104", "104,105", "106,105", "104,106", "105,106", "106,106"),
            hits(area, table("around", table("tree", true))), "around two trees, one at the corner of the loaded squares");
        // Two levels: the squares around are on the same level.
        IsoWorld.instance.currentCell.load(105, 105, 1).tree = true;
        same(set("101,100", "100,101", "101,101", "104,104", "105,104", "106,104", "104,105", "106,105", "104,106", "105,106", "106,106"),
            hits(area, table("around", table("tree", true))), "around ignores other levels");
    }

    // ---- the areas ----

    private static void areas(KahluaTable area) {
        grid();
        check(walk(area, whole(), null).equals(orderOf(X0, Y0, X0 + SIZE - 1, Y0 + SIZE - 1)), "A box is not walked row by row");
        check(walk(area, box(109, 103, 107, 102), null).equals(orderOf(107, 102, 109, 103)), "A box with its corners the other way round is not the same box");
        check(walk(area, box(95, 95, 101, 101), null).size() == 4, "A box with unloaded squares gave them");
        check(walk(area, table("x1", 100, "y1", 100, "x2", 101, "y2", 100, "z", 1), null).isEmpty(), "Another level has the squares of this one");

        for (double r : new double[] { 0, 1, 1.5, 2, 3.2 }) {
            double radius = r;
            var disc = table("x", 105, "y", 105, "z", 0, "r", radius);
            same(where((x, y) -> (x - 105) * (x - 105) + (y - 105) * (y - 105) <= radius * radius), new TreeSet<>(walk(area, disc, null)), "disc r = " + r);
        }
        same(where((x, y) -> (x - 104.5) * (x - 104.5) + (y - 105.5) * (y - 105.5) <= 2.25),
            new TreeSet<>(walk(area, table("x", 104.5, "y", 105.5, "z", 0, "r", 1.5), null)), "a disc round a point between squares");
        check(walk(area, table("x", 105, "y", 105, "z", 0, "r", 2), null).size() == 13, "A disc of 2 is not 13 squares");

        // Rings: nearest first; each ring is the squares whose larger of |dx| and |dy| is the ring.
        var rings = walk(area, table("x", 105, "y", 105, "z", 0, "to", 3), null);
        check(rings.size() == 49, "Rings 0 to 3 are not 49 squares: " + rings.size());
        int last = 0;
        for (String square : rings) {
            String[] parts = square.split(",");
            int ring = Math.max(Math.abs(Integer.parseInt(parts[0]) - 105), Math.abs(Integer.parseInt(parts[1]) - 105));
            check(ring >= last, "Rings are not nearest first at " + square);
            last = ring;
        }
        check(new HashSet<>(rings).size() == 49, "A square is in two rings");
        check(rings.get(0).equals("105,105"), "Ring 0 is not the point");
        var skipping = walk(area, table("x", 105, "y", 105, "z", 0, "from", 1, "to", 4, "step", 3), null);
        check(skipping.size() == 8 + 32 && skipping.stream().allMatch(s -> {
            String[] p = s.split(",");
            int ring = Math.max(Math.abs(Integer.parseInt(p[0]) - 105), Math.abs(Integer.parseInt(p[1]) - 105));
            return ring == 1 || ring == 4;
        }), "from, to and step: " + skipping.size());
        check(walk(area, table("x", 105, "y", 105, "z", 0, "from", 5, "to", 2), null).isEmpty(), "Rings from beyond to were not empty");

        // A list: those squares, in that order, the unloaded ones passed by.
        check(walk(area, table("list", list(103, 101, 0, 100, 100, 0, 5, 5, 0, 101, 100, 0)), null).equals(List.of("103,101", "100,100", "101,100")),
            "A list of squares");

        // A room: its rectangles on its level; as an IsoRoom, a RoomDef or an id.
        var grid = IsoWorld.instance.metaGrid;
        var def = new BuildingDef(false);
        var hall = new RoomDef(9200, "hall", 0, def);
        hall.rects.add(new RoomDef.RoomRect(101, 101, 2, 2));
        hall.rects.add(new RoomDef.RoomRect(106, 106, 1, 3));
        var loft = new RoomDef(9201, "loft", 1, def);
        loft.rects.add(new RoomDef.RoomRect(101, 101, 2, 1));
        grid.rooms.add(hall);
        grid.rooms.add(loft);
        try {
            Set<String> hallSquares = set("101,101", "102,101", "101,102", "102,102", "106,106", "106,107", "106,108");
            same(hallSquares, new TreeSet<>(walk(area, table("room", hall), null)), "a room as a RoomDef");
            same(hallSquares, new TreeSet<>(walk(area, table("room", "9200"), null)), "a room as its id");
            var iso = new IsoRoom(101, 101, 2, 2);
            iso.def = hall;
            same(hallSquares, new TreeSet<>(walk(area, table("room", iso), null)), "a room as an IsoRoom");
            check(walk(area, table("room", "9999"), null).isEmpty(), "A room nobody has gave squares");
            check(walk(area, table("room", "9201"), null).isEmpty(), "A room on a level with no loaded squares gave squares");
            for (int x = 101; x <= 102; x++) IsoWorld.instance.currentCell.load(x, 101, 1);
            check(walk(area, table("room", "9201"), null).size() == 2, "A room's squares are on its level");
            String key = (String)((KahluaTable)FormulasTest.call((KahluaTable)API.rawget("buildings"), "at", 101.0, 101.0, 0.0).get(0)).rawget("key");
            same(set("101,101", "102,101", "101,102", "102,102", "106,106", "106,107", "106,108"),
                new TreeSet<>(walk(area, table("building", key, "z", 0), null)), "a building on a level");
            check(walk(area, table("building", key), null).size() == 9, "A building's squares on all its levels: " + walk(area, table("building", key), null));
            check(walk(area, table("building", "1,1,0"), null).isEmpty(), "A key of no building gave squares");
        } finally {
            grid.rooms.remove(hall);
            grid.rooms.remove(loft);
        }

        // The limit: past 250,000 squares looked at, an error; fewer where the walk ends first.
        error(area, "list", "250000", table("x1", 0, "y1", 0, "x2", 999, "y2", 999, "z", 0), null);
        error(area, "list", "250000", table("x", 105, "y", 105, "z", 0, "to", 400), null);
        error(area, "list", "250000", table("x", 105, "y", 105, "z", 0, "r", 300), null);
        check(FormulasTest.call(area, "nearest", table("x", 105, "y", 105, "z", 0, "to", 100000), table("free", true)).get(0) == at(105, 105),
            "A walk that finds its square at once looked at more than it needed");
        check(walk(area, table("x1", 0, "y1", 0, "x2", 499, "y2", 499, "z", 0), table("free", false)).isEmpty(), "250,000 squares are allowed");
    }

    /** The "x,y" of a box in the order it is walked: row by row. */
    private static List<String> orderOf(int x1, int y1, int x2, int y2) {
        var result = new ArrayList<String>();
        for (int y = y1; y <= y2; y++) for (int x = x1; x <= x2; x++) result.add(x + "," + y);
        return result;
    }

    // ---- nearest ----

    private static void nearest(KahluaTable area) {
        grid();
        at(108, 106).freeOfObjects = false;
        at(103, 105).freeOfObjects = false;
        var rings = table("x", 105, "y", 105, "z", 0, "to", 4);
        var found = FormulasTest.call(area, "nearest", rings, table("free", false));
        check(found.get(0) == at(103, 105) && found.get(1).equals(2.0), "The nearest ring's square, and its ring: " + found);
        at(106, 104).freeOfObjects = false;
        found = FormulasTest.call(area, "nearest", rings, table("free", false));
        check(found.get(0) == at(106, 104) && found.get(1).equals(1.0), "The ring one square is on: " + found);
        found = FormulasTest.call(area, "nearest", table("x", 105, "y", 105, "z", 0, "from", 3, "to", 4), table("free", false));
        check(found.get(0) == at(108, 106) && found.get(1).equals(3.0), "from skips the rings before it: " + found);
        found = FormulasTest.call(area, "nearest", rings, table("tree", true));
        check(found.size() == 1 && found.get(0) == null, "A walk that finds nothing is nil: " + found);
        found = FormulasTest.call(area, "nearest", whole(), table("free", false));
        check(found.get(0) == at(106, 104) && found.size() == 1, "A box gives the first square in its order (row by row), and no ring: " + found);
        found = FormulasTest.call(area, "nearest", table("x", 105, "y", 105, "z", 0, "r", 5), null);
        check(found.get(0) != null && found.size() == 1, "nearest with no filter takes the first loaded square");
        found = FormulasTest.call(area, "nearest", table("x", 100, "y", 100, "z", 0, "to", 3), table("clear", table("r", 1, "filter", table("free", true))));
        check(found.get(0) == at(101, 101) && found.get(1).equals(1.0), "nearest with a clear filter skips the border of the loaded squares: " + found);
    }

    // ---- list ----

    private static void lists(KahluaTable area) {
        grid();
        check(names(FormulasTest.call(area, "list", whole(), null, table("limit", 5)).get(0)).equals(orderOf(100, 100, 104, 100)), "limit takes the first in the area's order");
        check(names(FormulasTest.call(area, "list", whole(), null, table("limit", 0)).get(0)).isEmpty(), "limit 0");
        check(names(FormulasTest.call(area, "list", whole(), null, table("limit", 500)).get(0)).size() == 100, "A limit above the squares");

        var near = names(FormulasTest.call(area, "list", whole(), null, table("near", table("x", 105, "y", 105), "limit", 5)).get(0));
        check(near.get(0).equals("105,105") && new TreeSet<>(near.subList(1, 5)).equals(set("104,105", "106,105", "105,104", "105,106")),
            "near: nearest first, the first of equals first: " + near);
        var all = names(FormulasTest.call(area, "list", whole(), null, table("near", table("x", 100, "y", 100))).get(0));
        check(all.size() == 100 && all.get(0).equals("100,100") && all.get(99).equals("109,109"), "near sorts all of them");
        double last = -1;
        for (String square : all) {
            String[] p = square.split(",");
            double d = Math.pow(Integer.parseInt(p[0]) - 100, 2) + Math.pow(Integer.parseInt(p[1]) - 100, 2);
            check(d >= last, "near is not sorted at " + square);
            last = d;
        }

        for (int y = Y0; y < Y0 + SIZE; y++) for (int x = X0; x < X0 + 5; x++) at(x, y).outdoors = true;
        Set<String> outdoors = where((x, y) -> x < 105);
        var seen = new HashSet<List<String>>();
        for (int trial = 0; trial < 30; trial++) {
            var picked = names(FormulasTest.call(area, "list", whole(), table("outside", true), table("random", 3)).get(0));
            check(picked.size() == 3 && new HashSet<>(picked).size() == 3 && outdoors.containsAll(picked), "random: 3 of the squares that meet the filter: " + picked);
            seen.add(picked);
        }
        check(seen.size() > 1, "random gave the same squares 30 times");
        check(names(FormulasTest.call(area, "list", whole(), table("outside", true), table("random", 500)).get(0)).size() == 50, "random above what there is");
        check(names(FormulasTest.call(area, "list", whole(), table("outside", true), table("random", 10, "limit", 4)).get(0)).size() == 4, "random with a limit");

        // connected: joined to the nearest passing square to the point by steps the game does not block, through squares that pass.
        grid();
        for (int y = Y0; y < Y0 + SIZE; y++) { at(104, y).blocked.add(at(105, y)); at(105, y).blocked.add(at(104, y)); }
        same(where((x, y) -> x < 105), new TreeSet<>(names(FormulasTest.call(area, "list", whole(), table("free", true), table("connected", table("x", 100, "y", 100))).get(0))),
            "connected: the side of the wall the point is on");
        same(where((x, y) -> x >= 105), new TreeSet<>(names(FormulasTest.call(area, "list", whole(), null, table("connected", table("x", 109, "y", 109))).get(0))),
            "connected: the other side");
        for (int x = X0; x < X0 + SIZE; x++) at(x, 103).freeOfObjects = false;
        same(where((x, y) -> x < 105 && y < 103), new TreeSet<>(names(FormulasTest.call(area, "list", whole(), table("free", true), table("connected", table("x", 100, "y", 100))).get(0))),
            "connected: squares that fail the filter cut the way");
        same(where((x, y) -> x < 105 && y > 103), new TreeSet<>(names(FormulasTest.call(area, "list", whole(), table("free", true), table("connected", table("x", 101, "y", 108))).get(0))),
            "connected: the nearest passing square to the point starts it");
        var connected = names(FormulasTest.call(area, "list", whole(), table("free", true), table("connected", table("x", 100, "y", 100), "limit", 3)).get(0));
        check(connected.equals(List.of("100,100", "101,100", "102,100")), "connected keeps the area's order and takes a limit: " + connected);
        check(names(FormulasTest.call(area, "list", whole(), table("tree", true), table("connected", table("x", 1, "y", 1))).get(0)).isEmpty(), "connected with nothing passing");
    }

    // ---- fit ----

    private static void fits(KahluaTable area) {
        grid();
        for (IsoGridSquare square : everySquare()) square.freeOfObjects = false;
        for (int y = 102; y <= 103; y++) for (int x = 103; x <= 105; x++) at(x, y).freeOfObjects = true;
        for (int x = 107; x <= 108; x++) at(x, 105).freeOfObjects = true;
        var free = table("free", true);
        // A 3 by 2 box of free squares first fits at (103, 102): the 24th square of the grid.
        var found = FormulasTest.call(area, "fit", whole(), list(table("box", list(0, 0, 2, 1), "filter", free)));
        check(found.get(0) == at(103, 102) && found.get(1).equals(24.0), "fit: the first anchor in the area's order, and its index: " + found);
        // The table of parts is read once, as a filter's is: used again it gives its shape without being read; changed after its first use it is
        // not read again (a mod makes a new one), and a new table with the new content is read.
        var parts = list(table("offsets", list(0, 0, 1, 0, 2, 0, 0, 1, 1, 1, 2, 1), "filter", free));
        for (int round = 0; round < 3; round++) {
            found = FormulasTest.call(area, "fit", whole(), parts);
            check(found.get(0) == at(103, 102), "fit by a table of parts used again: " + found);
        }
        ((KahluaTable)parts.rawget(1)).rawset((Object)"offsets", list(0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0));
        found = FormulasTest.call(area, "fit", whole(), parts);
        check(found.get(0) == at(103, 102), "fit by a table of parts changed after its first use is not read again: " + found);
        found = FormulasTest.call(area, "fit", whole(), list(table("offsets", list(0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0), "filter", free)));
        check(found.get(0) == null, "fit by a new table of parts is read: " + found);
        // A table that was wrong is told so each time it is used; the name of the wrong value is made for the message.
        var wrong = list(table("offsets", list(0, 0, 1), "filter", free));
        for (int round = 0; round < 2; round++) {
            try { FormulasTest.call(area, "fit", whole(), wrong); throw new AssertionError("Not refused"); }
            catch (IllegalArgumentException expected) { check(expected.getMessage().contains("parts[1].offsets must be a list"), "Wrong message: " + expected.getMessage()); }
        }
        wrong = list(table("offsets", list(0, 0, 1, 99999), "filter", free));
        try { FormulasTest.call(area, "fit", whole(), wrong); throw new AssertionError("Not refused"); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains("parts[1].offsets[4] must be a whole number"), "Wrong message: " + expected.getMessage()); }
        found = FormulasTest.call(area, "fit", whole(), list(table("offsets", list(0, 0, 1, 0, 2, 0, 0, 1, 1, 1, 2, 1), "filter", free)));
        check(found.get(0) == at(103, 102), "fit by offsets");
        found = FormulasTest.call(area, "fit", whole(), list(table("offsets", list(0, 0, 1, 0), "filter", free)), null);
        check(found.get(0) == at(103, 102), "fit of two squares");
        found = FormulasTest.call(area, "fit", whole(), list(table("box", list(0, 0, 4, 0, 4), "filter", free)));
        check(found.get(0) == null && found.size() == 1, "fit with a step of 4 over (0) and (4): nothing free that far apart: " + found);
        found = FormulasTest.call(area, "fit", whole(), list(table("box", list(0, 0, 4, 0, 2), "filter", table("free", true))));
        check(found.get(0) == null, "fit with a step of 2 over 0, 2 and 4: " + found);
        found = FormulasTest.call(area, "fit", whole(), list(table("box", list(0, 0, 2, 0, 2), "filter", free)));
        check(found.get(0) == at(103, 102), "fit with a step of 2 over 0 and 2: " + found);
        found = FormulasTest.call(area, "fit", whole(), list(table("box", list(0, 0, 3, 3), "filter", free)));
        check(found.get(0) == null, "fit of a shape that is not there is nil");
        // Two parts: free squares, and the square north of the anchor outside.
        at(104, 101).outdoors = true;
        found = FormulasTest.call(area, "fit", whole(), list(table("box", list(0, 0, 1, 1), "filter", free), table("offsets", list(0, -1), "filter", table("outside", true))));
        check(found.get(0) == at(104, 102), "fit with two parts: " + found);
        // The shape must be loaded: past the edge of the loaded squares it does not fit.
        for (IsoGridSquare square : everySquare()) square.freeOfObjects = true;
        found = FormulasTest.call(area, "fit", table("list", list(109, 109, 0)), list(table("offsets", list(0, 0, 1, 0), "filter", free)));
        check(found.get(0) == null, "fit past the loaded squares");
        found = FormulasTest.call(area, "fit", table("list", list(109, 109, 0, 108, 109, 0)), list(table("offsets", list(0, 0, 1, 0), "filter", free)));
        check(found.get(0) == at(108, 109) && found.get(1).equals(2.0), "fit by the index in the list: " + found);
        found = FormulasTest.call(area, "fit", table("list", list(1, 1, 0, 108, 109, 0)), list(table("offsets", list(0, 0, 1, 0), "filter", free)));
        check(found.get(0) == at(108, 109) && found.get(1).equals(2.0), "fit keeps the index of a list with an unloaded square");

        // Order random: any anchor that fits, its index its place in the area's order.
        var anchors = table("x", 105, "y", 105, "z", 0, "to", 3);
        var results = new HashSet<Object>();
        for (int trial = 0; trial < 40; trial++) {
            found = FormulasTest.call(area, "fit", anchors, list(table("offsets", list(0, 0, 1, 0), "filter", free)), table("order", "random"));
            check(found.get(0) != null && found.get(1) instanceof Double, "random order found nothing");
            results.add(found.get(0));
            var ring = names(FormulasTest.call(area, "list", anchors, null).get(0));
            check(ring.get((int)(double)(Double)found.get(1) - 1).equals(name(found.get(0))), "The index of a random fit is its place in the area's order");
        }
        check(results.size() > 3, "random order tried few anchors: " + results.size());
        found = FormulasTest.call(area, "fit", anchors, list(table("offsets", list(0, 0, 1, 0), "filter", free)), table("order", "area"));
        check(found.get(0) == at(105, 105) && found.get(1).equals(1.0), "order area is the default: " + found);
        for (IsoGridSquare square : everySquare()) square.freeOfObjects = false;
        found = FormulasTest.call(area, "fit", anchors, list(table("offsets", list(0, 0), "filter", free)), table("order", "random"));
        check(found.get(0) == null, "random order with no fit is nil");

        // room = "anchor": the anchor's own room.
        grid();
        var a = new IsoRoom(100, 100, 4, 1);
        var b = new IsoRoom(104, 100, 4, 1);
        a.def = new RoomDef(9301, "a");
        b.def = new RoomDef(9302, "b");
        for (int x = 100; x <= 103; x++) at(x, 100).room = a;
        for (int x = 104; x <= 107; x++) at(x, 100).room = b;
        var sameRoom = list(table("offsets", list(0, 0, 1, 0), "filter", table("room", "anchor")));
        found = FormulasTest.call(area, "fit", table("list", list(103, 100, 0, 104, 100, 0, 100, 100, 0)), sameRoom);
        check(found.get(0) == at(104, 100) && found.get(1).equals(2.0), "room = anchor: both squares in the anchor's room: " + found);
        found = FormulasTest.call(area, "fit", table("list", list(103, 100, 0, 107, 100, 0)), sameRoom);
        check(found.get(0) == null, "room = anchor: the anchor's room ends before the second square, and the second anchor's room ends at the edge: " + found);
        found = FormulasTest.call(area, "fit", table("list", list(107, 100, 0, 100, 101, 0)), list(table("offsets", list(0, 0, 1, 0), "filter", table("room", "anchor"))));
        check(found.get(0) == at(100, 101) && found.get(1).equals(2.0), "room = anchor: no room is the anchor's room too: " + found);
        found = FormulasTest.call(area, "fit", table("list", list(103, 100, 0)), list(table("offsets", list(0, 0, 1, 0), "filter", table("room", "any"))));
        check(found.get(0) == at(103, 100), "room = any");
        found = FormulasTest.call(area, "fit", table("list", list(103, 100, 0, 104, 100, 0)), list(table("offsets", list(0, 0, 1, 0), "filter", table("around", table("room", "anchor")))));
        check(found.get(0) == at(103, 100), "room = anchor inside around");
        found = FormulasTest.call(area, "fit", table("list", list(103, 100, 0, 104, 100, 0)), list(table("offsets", list(0, 0), "filter", table("clear", table("r", 1, "filter", table("room", "anchor"))))));
        check(found.get(0) == null, "room = anchor inside clear: the border squares are unloaded");
    }

    /** A call asks about at most 10,000,000 squares: 1,010 anchors of a shape of 9,901 squares that fits nowhere is past it. */
    private static void fitLimit(KahluaTable area) {
        var cell = new IsoCell();
        IsoWorld.instance.setCell(cell);
        for (int y = 0; y < 140; y++) for (int x = 0; x < 140; x++) cell.load(x, y, 0);
        var shape = list(table("box", list(0, 0, 99, 98), "filter", table("free", true)), table("offsets", list(0, 99), "filter", table("free", false)));
        error(area, "fit", "squares to ask about", table("x1", 0, "y1", 0, "x2", 39, "y2", 39, "z", 0), shape);
        // Fewer anchors are within it.
        check(FormulasTest.call(area, "fit", table("x1", 0, "y1", 0, "x2", 9, "y2", 9, "z", 0), shape).get(0) == null, "A shape that fits nowhere fit");
    }

    private static List<IsoGridSquare> everySquare() {
        var result = new ArrayList<IsoGridSquare>();
        for (int y = Y0; y < Y0 + SIZE; y++) for (int x = X0; x < X0 + SIZE; x++) result.add(at(x, y));
        return result;
    }

    // ---- reading a table once ----

    private static void caching() throws Throwable {
        grid();
        var lua = new Kahlua(LuaManager.class);
        var game = new Game(GAME);
        var filter = table("free", true, "around", table("tree", true));
        SquareFilter first = SquareFilter.read(lua, game, filter, "test");
        check(SquareFilter.read(lua, game, filter, "test") == first, "A table was read twice");
        check(SquareFilter.read(lua, game, table("free", true, "around", table("tree", true)), "test") != first, "A table was taken for another");
        filter.rawset("tree", false);
        filter.rawset("free", false);
        check(SquareFilter.read(lua, game, filter, "test") == first, "A table changed after its first use was read again");
        check(SquareFilter.read(lua, game, null, "test") == SquareFilter.read(lua, game, null, "test"), "nil is not one filter");
        try {
            SquareFilter.read(lua, game, table("room", "anchor"), "test").test(at(100, 100));
            throw new AssertionError("room = anchor was answered with no anchor");
        } catch (IllegalStateException expected) { check(expected.getMessage().contains("squares.fit"), expected.getMessage()); }
        check(SquareFilter.read(lua, game, table("room", "anchor"), "test").usesAnchor() && !first.usesAnchor(), "usesAnchor");
        // The shared classes as another area calls them.
        var seen = new ArrayList<String>();
        Areas.read(lua, game, table("x1", 100, "y1", 100, "x2", 101, "y2", 100, "z", 0), "test").each((square, x, y, z) -> { seen.add(x + "," + y + "," + z + (square == at(x, y) ? "" : "!")); return true; });
        check(seen.equals(List.of("100,100,0", "101,100,0")), "Areas.each: " + seen);
        seen.clear();
        Areas.read(lua, game, table("x1", 100, "y1", 100, "x2", 109, "y2", 109, "z", 0), "test").each((square, x, y, z) -> { seen.add(x + "," + y); return seen.size() < 3; });
        check(seen.size() == 3, "Areas.each did not stop when told");
        check(SquareFilter.read(lua, game, table("free", true), "test").test(at(100, 100)), "SquareFilter.test");
    }

    // ---- what a mod is told ----

    private static void error(Object table, String function, String message, Object... arguments) {
        try {
            FormulasTest.call(table, function, arguments);
            throw new AssertionError(function + " took " + java.util.Arrays.toString(arguments));
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message) && expected.getMessage().contains("PZExtAPI.squares." + function),
                "Expected '" + message + "' naming the call, got: " + expected.getMessage());
        }
    }

    private static void errors(KahluaTable area) {
        grid();
        error(area, "nearest", "area must be a table", "nope", null);
        error(area, "nearest", "area must be a table", null, null);
        error(area, "nearest", "area must have", table("x", 1), null);
        error(area, "nearest", "area.to does not go with", table("x", 1, "y", 1, "z", 0, "r", 1, "to", 3), null);
        error(area, "nearest", "area.z must be a whole number from -32 to 31", table("x1", 0, "y1", 0, "x2", 1, "y2", 1, "z", 40), null);
        error(area, "nearest", "area.x1 must be a whole number", table("x1", 0.5, "y1", 0, "x2", 1, "y2", 1, "z", 0), null);
        error(area, "nearest", "area.r must be a number", table("x", 1, "y", 1, "z", 0, "r", -1), null);
        error(area, "nearest", "area.step", table("x", 1, "y", 1, "z", 0, "to", 3, "step", 0), null);
        error(area, "nearest", "area.list", table("list", list(1, 2)), null);
        error(area, "nearest", "area.list[6]", table("list", list(1, 2, 0, 1, 99, 40)), null);
        error(area, "nearest", "area.building must be a building key", table("building", 3), null);
        error(area, "nearest", "filter must be a table", whole(), "nope");
        error(area, "nearest", "filter.nonsense is not a condition", whole(), table("nonsense", true));
        error(area, "nearest", "filter.free must be true or false", whole(), table("free", "yes"));
        error(area, "nearest", "filter.floorPrefix must be a list of strings", whole(), table("floorPrefix", "x"));
        error(area, "nearest", "filter.floorPrefix[1] must be a string", whole(), table("floorPrefix", list(1)));
        error(area, "nearest", "which is not a flag of the game", whole(), table("flags", list("noSuchFlag")));
        error(area, "nearest", "filter.room must be a room", whole(), table("room", "not a room"));
        error(area, "nearest", "filter.building must be", whole(), table("building", 4));
        error(area, "nearest", "filter.clear.r must be a whole number from 0 to 32", whole(), table("clear", table("r", 33)));
        error(area, "nearest", "filter.clear.filter.free must be true or false", whole(), table("clear", table("r", 1, "filter", table("free", 1))));
        error(area, "nearest", "filter.clear.x is not r or filter", whole(), table("clear", table("r", 1, "x", 1)));
        error(area, "nearest", "filter.distance needs min or max", whole(), table("distance", table("x", 1, "y", 1)));
        error(area, "nearest", "filter.around must be a table", whole(), table("around", true));
        error(area, "nearest", "filter.room = \"anchor\" is for the parts of squares.fit", whole(), table("room", "anchor"));
        error(area, "list", "filter.room = \"anchor\" is for the parts of squares.fit", whole(), table("around", table("room", "anchor")));
        error(area, "list", "options must be a table", whole(), null, "x");
        error(area, "list", "options.sort is not one of", whole(), null, table("sort", true));
        error(area, "list", "options.limit must be a whole number", whole(), null, table("limit", -1));
        error(area, "list", "options.near and options.random cannot be used together", whole(), null, table("near", table("x", 1, "y", 1), "random", 2));
        error(area, "list", "options.near must be { x =, y = }", whole(), null, table("near", 3));
        error(area, "list", "options.connected.x must be a number", whole(), null, table("connected", table("y", 1)));
        error(area, "fit", "parts must be a list", whole(), "x");
        error(area, "fit", "parts must hold at least one part", whole(), list());
        error(area, "fit", "parts[1] must be a table", whole(), list(1));
        error(area, "fit", "parts[1] must have offsets or box, one of them", whole(), list(table("filter", table())));
        error(area, "fit", "parts[1] must have offsets or box, one of them", whole(), list(table("offsets", list(0, 0), "box", list(0, 0, 1, 1))));
        error(area, "fit", "parts[1].offsets must be a list dx1, dy1", whole(), list(table("offsets", list(0, 0, 1))));
        error(area, "fit", "parts[1].box must have x2 >= x1", whole(), list(table("box", list(2, 0, 1, 0))));
        error(area, "fit", "parts[1].box[5]", whole(), list(table("box", list(0, 0, 1, 1, 0))));
        error(area, "fit", "parts[2].extra is not one of", whole(), list(table("offsets", list(0, 0)), table("offsets", list(0, 0), "extra", 1)));
        error(area, "fit", "the shape has more than 10000 squares", whole(), list(table("box", list(0, 0, 100, 100))));
        error(area, "fit", "options.order must be", whole(), list(table("offsets", list(0, 0))), table("order", "best"));
        error(area, "fit", "options.sort is not one of", whole(), list(table("offsets", list(0, 0))), table("sort", 1));
    }

    // ---- a newer API ----

    private static void takeover(KahluaTable api) throws Exception {
        var area = (KahluaTable)api.rawget("squares");
        grid();
        Object oldNearest = area.rawget("nearest"), oldList = area.rawget("list"), oldFit = area.rawget("fit");
        GameApi.register(LuaManager.class);
        for (String name : new String[] { "nearest", "list", "fit", "watch", "unwatch" }) check(area.rawget(name) != null, name + " is gone after a takeover");
        check(area.rawget("nearest") != oldNearest && area.rawget("fit") != oldFit, "The queries were not replaced");
        for (Object old : new Object[] { oldNearest, oldList, oldFit }) {
            try { ((JavaFunction)old).call(new LuaCallFrame(whole(), null), 2); throw new AssertionError("an old function worked"); }
            catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        }
        check(FormulasTest.call(area, "nearest", whole(), table("free", true)).get(0) == at(100, 100), "The new queries do not answer");
    }

    // ---- what it costs ----

    private static void cost(KahluaTable api) {
        var area = (KahluaTable)api.rawget("squares");
        var cell = new IsoCell();
        cell.dense(128, 1);
        IsoWorld.instance.setCell(cell);
        for (int y = 0; y < 100; y++) for (int x = 0; x < 100; x++) {
            var square = cell.load(x, y, 0);
            square.outdoors = (x + y) % 3 != 0;
            square.floor = new IsoObject(new IsoSprite("blends_natural_01_" + (x & 7)));
        }
        var rings = table("x", 50, "y", 50, "z", 0, "to", 30);
        // 61 by 61 squares of rings and a filter that never passes: the cheapest filter, then one that asks every kind of thing.
        var never = table("flags", list("burning"));
        var heavy = table("free", true, "solidFloor", true, "floorAvoid", list("water"), "noObjectData", "mark", "doorEdge", false,
            "clear", table("r", 1, "filter", table("free", true)), "around", table("outside", true), "zonesNot", list("Farm"),
            "distance", table("x", 50, "y", 50, "max", 100));
        for (var filter : new KahluaTable[] { never, heavy }) {
            for (int warm = 0; warm < (filter == never ? 3000 : 300); warm++) FormulasTest.call(area, filter == never ? "nearest" : "list", rings, filter);
        }
        int rounds = 3000, squares = 61 * 61;
        long start = System.nanoTime();
        for (int n = 0; n < rounds; n++) FormulasTest.call(area, "nearest", rings, never);
        double nearest = (System.nanoTime() - start) / (double)rounds / squares;
        long bytes = Allocations.median(7, () -> { for (int n = 0; n < 100; n++) FormulasTest.call(area, "nearest", rings, never); });
        check(bytes < 100 * 4096, "nearest allocated " + bytes / 100 + " bytes a call over " + squares + " squares");
        start = System.nanoTime();
        Object result = null;
        for (int n = 0; n < 300; n++) result = FormulasTest.call(area, "list", rings, heavy).get(0);
        double listed = (System.nanoTime() - start) / 300.0 / squares;
        check(((KahluaTable)result).len() > 1000, "The heavy filter passed too few squares: " + ((KahluaTable)result).len());

        // A shape of 64 squares over 500 anchors: all but the last square of it fit, so every anchor is tried to the end.
        var anchors = table("x1", 10, "y1", 10, "x2", 34, "y2", 29, "z", 0);
        var eight = list(0, 0, 7, 7, 1);
        var shape = list(table("box", eight, "filter", table("free", true)), table("offsets", list(8, 8), "filter", table("free", false)));
        var sameRoom = list(table("box", eight, "filter", table("free", true, "room", "anchor")), table("offsets", list(8, 8), "filter", table("room", "anchor", "free", false)));
        for (int warm = 0; warm < 300; warm++) { FormulasTest.call(area, "fit", anchors, shape); FormulasTest.call(area, "fit", anchors, sameRoom); }
        start = System.nanoTime();
        for (int n = 0; n < 300; n++) check(FormulasTest.call(area, "fit", anchors, shape).get(0) == null, "The shape fit");
        double fit = (System.nanoTime() - start) / 300.0 / (500 * 65);
        start = System.nanoTime();
        for (int n = 0; n < 300; n++) FormulasTest.call(area, "fit", anchors, sameRoom);
        double anchored = (System.nanoTime() - start) / 300.0 / (500 * 65);
        long fitBytes = Allocations.median(7, () -> { for (int n = 0; n < 10; n++) FormulasTest.call(area, "fit", anchors, shape); });
        check(fitBytes < 10 * 8192, "fit allocated " + fitBytes / 10 + " bytes a call over 500 anchors");
        System.out.printf("squares: nearest over %d squares of rings with a filter that never passes costs %.1f ns a square (%d bytes a call); "
            + "list with a filter of nine kinds of condition %.1f ns a square; fit of a 65-square shape over 500 anchors %.1f ns a square asked (%.1f with room = anchor, which remembers nothing), %d bytes a call%n",
            squares, nearest, bytes / 100, listed, fit, anchored, fitBytes / 10);
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
