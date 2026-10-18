package pzext.api;

import java.util.ArrayList;
import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.Lua.LuaManager;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.inventory.types.InventoryContainer;
import zombie.iso.BuildingDef;
import zombie.iso.IsoCell;
import zombie.iso.IsoDirections;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;
import zombie.iso.areas.IsoRoom;
import zombie.iso.objects.IsoDoor;
import zombie.iso.objects.IsoThumpable;
import zombie.iso.objects.IsoTree;
import zombie.iso.objects.IsoWindow;
import zombie.iso.sprite.IsoSprite;

/**
 * {@code PZExtAPI.objects} against the synthetic game: the object match (every key), {@code find} with its options, {@code byData}
 * (found, missing, unloaded), {@code edges} of a room and of a building (doors, windows, facing objects, doorways, the outer side),
 * {@code remove} (recalculations once a square, sprite-grid objects whole, {@code keep}, {@code falloff}), the arguments it refuses, a
 * newer API taking over, and what a search costs an object.
 */
final class ObjectsTest {
    private static final ClassLoader GAME = ObjectsTest.class.getClassLoader();

    private ObjectsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        var grid = IsoWorld.instance.metaGrid;
        int rooms = grid.rooms.size();
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            var area = (KahluaTable)api.rawget("objects");
            check(area != null && area.rawget("find") != null && area.rawget("byData") != null && area.rawget("edges") != null
                && area.rawget("remove") != null, "PZExtAPI.objects is missing");
            matching(area);
            options(area);
            byData(area);
            edges(area);
            removing(area);
            refusals(area);
            takeover(api);
            cost((KahluaTable)api.rawget("objects"));
        } finally {
            while (grid.rooms.size() > rooms) grid.rooms.remove(grid.rooms.size() - 1);
            IsoWorld.instance.setCell(home);
            GameApi.frame(GAME);
        }
    }

    // ---- helpers ----

    private static IsoCell cell() { return IsoWorld.instance.currentCell; }

    private static Object norm(Object value) { return value instanceof Integer number ? (Object)number.doubleValue() : value; }

    private static KahluaTable table(Object... pairs) {
        var table = new KahluaTableImpl();
        for (int at = 0; at < pairs.length; at += 2) table.rawset((Object)pairs[at], norm(pairs[at + 1]));
        return table;
    }

    private static KahluaTable list(Object... values) {
        var table = new KahluaTableImpl();
        for (int at = 0; at < values.length; at++) table.rawset((Object)(double)(at + 1), norm(values[at]));
        return table;
    }

    private static KahluaTable box(int x1, int y1, int x2, int y2, int z) { return table("x1", x1, "y1", y1, "x2", x2, "y2", y2, "z", z); }

    private static <T extends IsoObject> T put(T object, int x, int y, int z) {
        object.square = cell().load(x, y, z);
        object.square.objects.add(object);
        return object;
    }

    private static <T extends IsoObject> T put(T object, int x, int y) { return put(object, x, y, 0); }

    private static IsoObject thing(String sprite) { return new IsoObject(new IsoSprite(sprite)); }

    private static void mark(IsoObject object, String key, Object value) { ((KahluaTable)object.getModData()).rawset((Object)key, norm(value)); }

    private static Object call(Object table, String name, Object... arguments) {
        List<Object> result = FormulasTest.call(table, name, arguments);
        return result.isEmpty() ? null : result.get(0);
    }

    private static List<Object> items(Object result) {
        var table = (KahluaTable)result;
        var found = new ArrayList<Object>();
        for (int at = 1; at <= table.len(); at++) found.add(table.rawget(at));
        return found;
    }

    private static List<Object> find(KahluaTable area, Object where, Object match) { return items(call(area, "find", where, match)); }

    private static void same(List<Object> found, String message, Object... expected) {
        check(found.size() == expected.length, message + ": found " + found.size() + " objects, expected " + expected.length);
        for (int at = 0; at < expected.length; at++) check(found.get(at) == expected[at], message + ": object " + at + " is not the expected one");
    }

    private static void refuses(String message, Runnable call) {
        try { call.run(); }
        catch (IllegalArgumentException expected) { check(expected.getMessage().contains(message), "Wrong message: " + expected.getMessage()); return; }
        throw new AssertionError("Not refused: " + message);
    }

    // ---- the match ----

    /** Every key of a match, on a row of objects. */
    private static void matching(KahluaTable area) {
        IsoObject shelf = put(thing("furn_a1"), 3010, 3010);
        shelf.sprite.properties.named.put("IsMoveAble", "");
        var shelves = new ItemContainer(shelf);
        shelves.type = "shelves";
        shelf.containers.add(shelves);
        IsoObject crate = put(new IsoThumpable(new IsoSprite("furn_b1")), 3011, 3010);
        mark(crate, "mark", 5);
        IsoObject door = put(new IsoDoor(new IsoSprite("door_c")), 3012, 3010);
        IsoObject table = put(thing("furn_a2"), 3013, 3010);
        mark(table, "mark", "x");
        table.sprite.properties.named.put("Surface", "34");
        IsoObject tree = put(new IsoTree(), 3014, 3010);
        IsoObject chest = put(thing("furn_c3"), 3015, 3010);
        var bag = new InventoryContainer("Container", 1f, 20);
        var inner = new InventoryContainer("Container", 1f, 20);
        var key = new InventoryItem("Item", 0.1f);
        key.fullType = "Base.Key1";
        bag.getInventory().AddItem(inner);
        inner.getInventory().AddItem(key);
        var box = new ItemContainer(chest);
        box.AddItem(bag);
        chest.containers.add(box);
        IsoObject window = put(new IsoWindow(new IsoSprite("win_d")), 3016, 3010);
        var where = box(3010, 3010, 3016, 3010, 0);

        same(find(area, where, table()), "an empty match takes every object", shelf, crate, door, table, tree, chest, window);
        same(find(area, where, table("class", list("IsoDoor"))), "class", door);
        same(find(area, where, table("class", list("IsoDoor", "IsoThumpable"))), "two classes", crate, door);
        same(find(area, where, table("class", list("IsoObject"))), "a class and its subclasses", shelf, crate, door, table, tree, chest, window);
        same(find(area, where, table("notClass", list("IsoThumpable", "IsoDoor", "IsoWindow", "IsoTree"))), "notClass", shelf, table, chest);
        same(find(area, where, table("class", list("IsoObject"), "notClass", list("IsoDoor"))), "class and notClass",
            shelf, crate, table, tree, chest, window);
        same(find(area, where, table("sprite", list("furn_b1", "door_c"))), "sprite", crate, door);
        same(find(area, where, table("spritePrefix", list("furn_a", "win"))), "spritePrefix", shelf, table, window);
        same(find(area, where, table("sprite", list("furn_a1", "furn_a2"), "spritePrefix", list("furn_a2"))), "sprite and spritePrefix", table);
        same(find(area, where, table("props", list("IsMoveAble"))), "props", shelf);
        same(find(area, where, table("props", list("IsMoveAble", "Surface"))), "props, all of them");
        same(find(area, where, table("propIn", table("Surface", list("34", "35")))), "propIn", table);
        same(find(area, where, table("propIn", table("Surface", list(34)))), "propIn, a number", table);
        same(find(area, where, table("propIn", table("Surface", list("35")))), "propIn, no such value");
        same(find(area, where, table("propIn", table("Surface", list("35", false)), "spritePrefix", list("furn"))), "propIn, absent", shelf, crate, chest);
        same(find(area, where, table("data", "mark")), "data key", crate, table);
        same(find(area, where, table("data", table("mark", 5))), "data number", crate);
        same(find(area, where, table("data", table("mark", "x"))), "data string", table);
        same(find(area, where, table("data", table("mark", "5"))), "a string is not a number");
        same(find(area, where, table("noData", "mark", "class", list("IsoObject"), "spritePrefix", list("furn"))), "noData", shelf, chest);
        check(shelf.hasModData() == false, "A match made mod data for an object that had none");
        same(find(area, where, table("container", true)), "container", shelf, chest);
        same(find(area, where, table("holds", table("type", list("Base.Key1")))), "holds, in a bag in a bag", chest);
        same(find(area, where, table("holds", table("type", list("Base.Nothing")))), "holds, no such item");
        same(find(area, where, table("holds", table("type", list("Base.Key1")), "data", "mark")), "holds and data");
        // The floor's own list of objects is not touched: the same table, used again, is not read again.
        var cached = table("sprite", list("furn_b1"));
        same(find(area, where, cached), "cached match, first", crate);
        cached.rawset((Object)"sprite", list("door_c"));
        same(find(area, where, cached), "cached match, changed after its first use", crate);
        same(find(area, where, table("sprite", list("door_c"))), "a new table is read", door);
    }

    /** The options of find, and the areas it looks in. */
    private static void options(KahluaTable area) {
        var where = box(3010, 3010, 3016, 3010, 0);
        var any = table("class", list("IsoObject"));
        check(find(area, where, any).size() == 7, "Seven objects are expected");
        check(find(area, where, table()).size() == 7, "An empty match is expected to take all");
        check(items(call(area, "find", where, any, table("limit", 3))).size() == 3, "limit 3");
        check(items(call(area, "find", where, any, table("limit", 0))).isEmpty(), "limit 0");
        // squares: a filter the object's square meets.
        cell().getGridSquare(3012, 3010, 0).outsideSquare = true;
        cell().getGridSquare(3013, 3010, 0).outsideSquare = true;
        var found = items(call(area, "find", where, any, table("squares", table("outside", true))));
        check(found.size() == 2 && ((IsoObject)found.get(0)).square.x == 3012 && ((IsoObject)found.get(1)).square.x == 3013, "squares filter: " + found.size());
        check(items(call(area, "find", where, any, table("squares", table("outside", false), "limit", 2))).size() == 2, "squares and limit");
        // Other areas.
        check(find(area, table("x", 3012, "y", 3010, "z", 0, "r", 1.5), any).size() == 3, "circle");
        check(find(area, table("list", list(3010, 3010, 0, 3016, 3010, 0)), any).size() == 2, "list");
        check(find(area, box(3010, 3011, 3016, 3011, 0), any).isEmpty(), "squares that are not loaded hold nothing");
        check(find(area, box(3010, 3010, 3016, 3010, 1), any).isEmpty(), "another level");
    }

    // ---- byData ----

    private static void byData(KahluaTable area) {
        IsoObject numbered = put(thing("unit_a"), 3050, 3050);
        mark(numbered, "unit", 7);
        IsoObject named = put(thing("unit_b"), 3051, 3050);
        mark(named, "unit", "pump");
        IsoObject other = put(thing("unit_c"), 3051, 3050);
        mark(other, "unit", "tank");
        IsoObject unmarked = put(thing("unit_d"), 3052, 3050);
        IsoObject up = put(thing("unit_e"), 3050, 3050, 1);
        mark(up, "unit", 7);
        var found = items(call(area, "byData", "unit", list(
            3050, 3050, 0, 7,
            3051, 3050, 0, "tank",
            3051, 3050, 0, "pump",
            3050, 3050, 0, 8,
            3050, 3050, 0, "7",
            3052, 3050, 0, 7,
            3053, 3050, 0, 7,
            3050, 3050, 1, 7,
            3050, 3050, 2, 7,
            9000, 9000, 0, 7)));
        check(found.size() == 10, "One result for each entry: " + found.size());
        check(found.get(0) == numbered && found.get(1) == other && found.get(2) == named, "The objects are not the ones with the values");
        check(found.get(3) == Boolean.FALSE && found.get(4) == Boolean.FALSE, "A value that is not there is not false: " + found.get(3) + ", " + found.get(4));
        check(found.get(5) == Boolean.FALSE && unmarked.hasModData() == false, "An object without data is not false, or got data");
        check(found.get(6) == Boolean.FALSE, "A missing square of a loaded chunk is not false: " + found.get(6));
        check(found.get(7) == up && found.get(8) == Boolean.FALSE, "Levels are not told apart");
        check("unloaded".equals(found.get(9)), "A square of no chunk is not unloaded: " + found.get(9));
        var chunk = cell().getChunk(3050 / 8, 3050 / 8);
        chunk.loaded = false;
        check("unloaded".equals(items(call(area, "byData", "unit", list(3053, 3050, 0, 7))).get(0)), "A square of a chunk not loaded is not unloaded");
        chunk.loaded = true;
        check(items(call(area, "byData", "unit", list())).isEmpty(), "an empty list");
        check(items(call(area, "byData", "unit", list(3050, 3050, 0, true))).get(0) == Boolean.FALSE, "a boolean value");
        refuses("x1, y1, z1, v1", () -> call(area, "byData", "unit", list(1, 2, 3)));
        refuses("must be a whole number", () -> call(area, "byData", "unit", list(1.5, 2, 3, 4)));
        refuses("key must be a string", () -> call(area, "byData", 3, list(1, 2, 3, 4)));
        refuses("number, string or boolean", () -> call(area, "byData", "unit", list(1, 2, 3, table())));
    }

    // ---- edges ----

    private static void edges(KahluaTable area) {
        var grid = IsoWorld.instance.metaGrid;
        var house = new BuildingDef(false);
        var hall = new RoomDef(9001, "hall", 0, house);
        hall.rects.add(new RoomDef.RoomRect(3100, 3100, 4, 3));
        var side = new RoomDef(9002, "side", 0, house);
        side.rects.add(new RoomDef.RoomRect(3104, 3100, 2, 3));
        var upstairs = new RoomDef(9003, "upstairs", 1, house);
        upstairs.rects.add(new RoomDef.RoomRect(3100, 3100, 6, 3));
        grid.rooms.add(hall);
        grid.rooms.add(side);
        grid.rooms.add(upstairs);
        for (int y = 3098; y <= 3104; y++) for (int x = 3098; x <= 3107; x++) cell().load(x, y, 0);
        IsoDoor north = put(new IsoDoor(new IsoSprite("door")), 3101, 3100);
        north.north = true;
        IsoWindow west = put(new IsoWindow(new IsoSprite("window")), 3100, 3101);
        IsoDoor between = put(new IsoDoor(new IsoSprite("door")), 3104, 3101);
        IsoDoor frame = put(new IsoDoor(new IsoSprite("door")), 3100, 3102);
        IsoThumpable wall = put(new IsoThumpable(new IsoSprite("wall")), 3102, 3103);
        wall.north = true;
        IsoThumpable far = put(new IsoThumpable(new IsoSprite("wall")), 3109, 3103);
        IsoThumpable upper = put(new IsoThumpable(new IsoSprite("wall")), 3101, 3100, 1);
        upper.north = true;
        cell().load(3101, 3100, 1);
        cell().getGridSquare(3102, 3100, 0).northDoor = true;
        cell().getGridSquare(3104, 3102, 0).westDoor = true;
        cell().getGridSquare(3100, 3102, 0).westDoor = true;
        var solids = table("class", list("IsoDoor", "IsoWindow", "IsoThumpable"));
        var inHall = table("room", hall);

        var found = items(call(area, "edges", inHall, solids));
        edgesAre(found, "the hall", new Object[] { north, 3101, 3100, true, true }, new Object[] { west, 3100, 3101, false, true },
            new Object[] { between, 3104, 3101, false, false }, new Object[] { frame, 3100, 3102, false, true },
            new Object[] { wall, 3102, 3103, true, false });
        // The room as the game's room, and by its id.
        var room = new IsoRoom(3100, 3100, 4, 3);
        room.def = hall;
        check(items(call(area, "edges", table("room", room), solids)).size() == 5, "an IsoRoom");
        check(items(call(area, "edges", table("room", "9001"), solids)).size() == 5, "a room id");
        check(items(call(area, "edges", table("room", "123456"), solids)).isEmpty(), "a room the map does not have");
        found = items(call(area, "edges", inHall, solids, table("outer", true)));
        edgesAre(found, "the hall, outer", new Object[] { north, 3101, 3100, true, true }, new Object[] { west, 3100, 3101, false, true },
            new Object[] { frame, 3100, 3102, false, true }, new Object[] { wall, 3102, 3103, true, false });
        found = items(call(area, "edges", inHall, solids, table("doorways", true)));
        edgesAre(found, "the hall, doorways", new Object[] { north, 3101, 3100, true, true }, new Object[] { null, 3102, 3100, true, true },
            new Object[] { west, 3100, 3101, false, true }, new Object[] { between, 3104, 3101, false, false },
            new Object[] { frame, 3100, 3102, false, true }, new Object[] { null, 3104, 3102, false, false },
            new Object[] { wall, 3102, 3103, true, false });
        found = items(call(area, "edges", inHall, solids, table("doorways", true, "outer", true)));
        edgesAre(found, "the hall, doorways and outer", new Object[] { north, 3101, 3100, true, true }, new Object[] { null, 3102, 3100, true, true },
            new Object[] { west, 3100, 3101, false, true }, new Object[] { frame, 3100, 3102, false, true },
            new Object[] { wall, 3102, 3103, true, false });
        // A building on one level: the edge between its rooms is inside it; another level has its own.
        String key = "3100,3100,0";
        found = items(call(area, "edges", table("building", key, "z", 0), solids));
        edgesAre(found, "the building", new Object[] { north, 3101, 3100, true, true }, new Object[] { west, 3100, 3101, false, true },
            new Object[] { frame, 3100, 3102, false, true }, new Object[] { wall, 3102, 3103, true, false });
        found = items(call(area, "edges", table("building", key, "z", 1), solids));
        edgesAre(found, "the building above", new Object[] { upper, 3101, 3100, true, true });
        check(items(call(area, "edges", table("building", "1,2,3", "z", 0), solids)).isEmpty(), "a building the map does not have");
        // Objects with a facing of their own: north and west count, the others have no edge.
        IsoObject facingNorth = put(thing("fx"), 3103, 3100);
        facingNorth.sprite.facing = IsoDirections.N;
        IsoObject facingWest = put(thing("fx"), 3101, 3102);
        facingWest.sprite.facing = IsoDirections.W;
        IsoObject facingSouth = put(thing("fx"), 3102, 3102);
        facingSouth.sprite.facing = IsoDirections.S;
        put(thing("fx"), 3103, 3102);
        found = items(call(area, "edges", inHall, table("sprite", list("fx"))));
        edgesAre(found, "facing objects", new Object[] { facingNorth, 3103, 3100, true, true });
        facingWest.sprite.facing = IsoDirections.W;
        found = items(call(area, "edges", table("room", side), table("sprite", list("fx"))));
        check(found.isEmpty(), "The side room has no facing object on its edge");
        // A match that takes nothing: only the doorways are left.
        found = items(call(area, "edges", inHall, table("sprite", list("none")), table("doorways", true)));
        edgesAre(found, "only doorways", new Object[] { null, 3102, 3100, true, true }, new Object[] { null, 3104, 3102, false, false });
        refuses("target must be", () -> call(area, "edges", table(), solids));
        refuses("target must be", () -> call(area, "edges", table("room", hall, "building", key), solids));
        refuses("target.z", () -> call(area, "edges", table("building", key), solids));
        refuses("target.room must be a room", () -> call(area, "edges", table("room", 5), solids));
        refuses("is not an option", () -> call(area, "edges", inHall, solids, table("inside", true)));
        check(far.square != null, "unused object kept");
    }

    /** The list is the edges given: object (or null), x, y, north, inside. */
    private static void edgesAre(List<Object> found, String what, Object[]... expected) {
        check(found.size() == expected.length, what + ": " + found.size() + " edges, expected " + expected.length);
        for (int at = 0; at < expected.length; at++) {
            var entry = (KahluaTable)found.get(at);
            Object[] want = expected[at];
            check(entry.rawget((Object)"object") == want[0], what + ": edge " + at + " has the wrong object");
            check(entry.rawget((Object)"x").equals(((Number)want[1]).doubleValue()) && entry.rawget((Object)"y").equals(((Number)want[2]).doubleValue()),
                what + ": edge " + at + " is at " + entry.rawget((Object)"x") + ", " + entry.rawget((Object)"y"));
            check(entry.rawget((Object)"z") instanceof Double, what + ": z");
            check(entry.rawget((Object)"north").equals(want[3]), what + ": edge " + at + " north is " + entry.rawget((Object)"north"));
            check(entry.rawget((Object)"inside").equals(want[4]), what + ": edge " + at + " inside is " + entry.rawget((Object)"inside"));
        }
    }

    // ---- remove ----

    private static void removing(KahluaTable area) {
        // Two objects to go on a square and one to stay, the recalculations once a square.
        IsoObject junk = put(thing("junk_1"), 3200, 3200);
        IsoObject junkToo = put(thing("junk_2"), 3200, 3200);
        IsoObject stays = put(thing("keep_1"), 3200, 3200);
        IsoObject junkNext = put(thing("junk_1"), 3201, 3200);
        IsoObject cleanSquare = put(thing("keep_2"), 3202, 3200);
        IsoObject far = put(thing("junk_3"), 3210, 3200);
        for (int x = 3200; x <= 3202; x++) { cell().getGridSquare(x, 3200, 0).recalcs = 0; cell().getGridSquare(x, 3200, 0).neighbourRecalcs = 0; }
        var where = box(3200, 3200, 3202, 3200, 0);
        Object count = call(area, "remove", where, table("spritePrefix", list("junk_")));
        check(Double.valueOf(3).equals(count), "Three objects should go, not " + count);
        var square = cell().getGridSquare(3200, 3200, 0);
        check(square.objects.size() == 1 && square.objects.get(0) == stays, "Wrong objects stayed on the square");
        check(cell().getGridSquare(3201, 3200, 0).objects.isEmpty() && cell().getGridSquare(3202, 3200, 0).objects.size() == 1, "Wrong objects stayed");
        check(square.recalcs == 1 && square.neighbourRecalcs == 1, "The square lost two objects but was worked out " + square.recalcs + " and " + square.neighbourRecalcs + " times");
        check(cell().getGridSquare(3201, 3200, 0).recalcs == 1 && cell().getGridSquare(3202, 3200, 0).recalcs == 0
            && cell().getGridSquare(3202, 3200, 0).neighbourRecalcs == 0, "A square that lost nothing was worked out, or one that did was not");
        check(far.square.objects.size() == 1, "An object out of the area went");
        check(Double.valueOf(0).equals(call(area, "remove", where, table("spritePrefix", list("junk_")))), "Nothing is left to take");

        // squares: only those whose square meets the filter.
        IsoObject out = put(thing("junk_4"), 3220, 3200);
        IsoObject in = put(thing("junk_4"), 3221, 3200);
        out.square.outsideSquare = true;
        check(Double.valueOf(1).equals(call(area, "remove", box(3220, 3200, 3221, 3200, 0), table("sprite", list("junk_4")),
            table("squares", table("outside", true)))), "squares filter");
        check(out.square.objects.isEmpty() && in.square.objects.size() == 1, "The wrong square was cleared");

        // An object that covers two squares goes whole, even when only one part is in the area.
        IsoObject left = put(thing("grid_a"), 3230, 3200);
        IsoObject right = put(thing("grid_a"), 3231, 3200);
        left.gridParts.add(right);
        right.gridParts.add(left);
        IsoObject plain = put(thing("grid_a"), 3230, 3200);
        for (int x = 3230; x <= 3231; x++) { cell().getGridSquare(x, 3200, 0).recalcs = 0; cell().getGridSquare(x, 3200, 0).neighbourRecalcs = 0; }
        check(Double.valueOf(2).equals(call(area, "remove", box(3230, 3200, 3230, 3200, 0), table("sprite", list("grid_a")))), "A grid object is one object");
        check(left.square.objects.isEmpty() && right.square.objects.isEmpty() && plain.square.objects.isEmpty(), "A part of a grid object stayed");
        check(cell().getGridSquare(3231, 3200, 0).recalcs == 1 && cell().getGridSquare(3231, 3200, 0).neighbourRecalcs == 1,
            "The square of the other part was not worked out");
        // Both parts in the area are one object.
        IsoObject l2 = put(thing("grid_b"), 3232, 3200);
        IsoObject r2 = put(thing("grid_b"), 3233, 3200);
        l2.gridParts.add(r2);
        r2.gridParts.add(l2);
        check(Double.valueOf(1).equals(call(area, "remove", box(3232, 3200, 3233, 3200, 0), table("sprite", list("grid_b")))), "Both parts are one object");

        // keep: an object, or any part of one, that matches it stays whole.
        IsoObject marked = put(thing("junk_5"), 3240, 3200);
        mark(marked, "keepme", true);
        IsoObject unmarked = put(thing("junk_5"), 3241, 3200);
        IsoObject l3 = put(thing("grid_c"), 3242, 3200);
        IsoObject r3 = put(thing("grid_c"), 3243, 3200);
        l3.gridParts.add(r3);
        r3.gridParts.add(l3);
        mark(r3, "keepme", true);
        IsoObject l4 = put(thing("grid_c"), 3244, 3200);
        IsoObject r4 = put(thing("grid_c"), 3245, 3200);
        l4.gridParts.add(r4);
        r4.gridParts.add(l4);
        var keep = table("data", "keepme");
        count = call(area, "remove", box(3240, 3200, 3245, 3200, 0), table("spritePrefix", list("junk_5", "grid_c")), table("keep", keep));
        check(Double.valueOf(2).equals(count), "keep: two objects should go, not " + count);
        check(marked.square.objects.size() == 1 && unmarked.square.objects.isEmpty(), "keep: the marked object went or the other stayed");
        check(l3.square.objects.size() == 1 && r3.square.objects.size() == 1, "keep: a part that matched keep did not keep the whole");
        check(l4.square.objects.isEmpty() && r4.square.objects.isEmpty(), "keep: an object with no part to keep stayed");
        // A part kept is kept even when only the other part is in the area.
        check(Double.valueOf(0).equals(call(area, "remove", box(3242, 3200, 3242, 3200, 0), table("sprite", list("grid_c")), table("keep", keep))),
            "keep: a part outside the area did not keep the whole");

        falloff(area);
        refuses("is not an option", () -> call(area, "remove", where, table(), table("limit", 1)));
        refuses("falloff needs", () -> call(area, "remove", where, table(), table("falloff", table("x", 0, "y", 0, "inner", 5, "outer", 2))));
        refuses("options.falloff.x", () -> call(area, "remove", where, table(), table("falloff", table("y", 0, "inner", 1, "outer", 2))));
        refuses("match must be a table", () -> call(area, "remove", where, "all"));
    }

    /** Beyond the inner radius a square is cleared with the chance (outer - d) / (outer - inner). */
    private static void falloff(KahluaTable area) {
        var objects = new IsoObject[8];
        for (int d = 0; d < objects.length; d++) objects[d] = put(thing("fall"), 3300 + d, 3300);
        var around = table("x", 3300, "y", 3300, "inner", 2, "outer", 6);
        var row = box(3300, 3300, 3307, 3300, 0);
        var match = table("sprite", list("fall"));
        var before = ObjectQueries.dice;
        try {
            ObjectQueries.dice = () -> 0.5;
            check(Double.valueOf(4).equals(call(area, "remove", row, match, table("falloff", around))), "falloff at 0.5: distances 0, 1, 2 and 3 go");
            boolean[] gone = new boolean[objects.length];
            for (int d = 0; d < objects.length; d++) gone[d] = objects[d].square.objects.isEmpty();
            check(gone[0] && gone[1] && gone[2] && gone[3] && !gone[4] && !gone[5] && !gone[6] && !gone[7], "falloff at 0.5: " + java.util.Arrays.toString(gone));
            ObjectQueries.dice = () -> 0.0;
            check(Double.valueOf(2).equals(call(area, "remove", row, match, table("falloff", around))), "falloff at 0: distances 4 and 5 go, 6 never");
            check(!objects[6].square.objects.isEmpty() && objects[6].square.objects.size() == 1 && objects[7].square.objects.size() == 1, "A square at outer or beyond was cleared");
            ObjectQueries.dice = () -> 0.9999;
            check(Double.valueOf(0).equals(call(area, "remove", row, match, table("falloff", around))), "falloff at 0.9999: nothing beyond inner goes");
            // outer = inner: a hard edge.
            check(Double.valueOf(0).equals(call(area, "remove", row, match, table("falloff", table("x", 3300, "y", 3300, "inner", 2, "outer", 2)))), "A hard edge");
        } finally { ObjectQueries.dice = before; }
        // The real dice: squares one distance from the point, on 30 levels, some are cleared and some are not.
        var levels = new ArrayList<Object>();
        for (int z = -20; z <= 9; z++) { put(thing("roll"), 3340, 3300, z); levels.add(3340); levels.add(3300); levels.add(z); }
        Object count = call(area, "remove", table("list", list(levels.toArray())), table("sprite", list("roll")),
            table("falloff", table("x", 3338, "y", 3300, "inner", 1, "outer", 3)));
        double gone = (Double)count;
        check(gone > 2 && gone < 28, "A chance of one half cleared " + gone + " of 30");
    }

    // ---- refusals and takeover ----

    private static void refusals(KahluaTable area) {
        var where = box(0, 0, 1, 1, 0);
        refuses("area must be a table", () -> call(area, "find", "here", table()));
        refuses("match must be a table", () -> call(area, "find", where, null));
        refuses("match must be a table", () -> call(area, "find", where, "IsoDoor"));
        refuses("match.bogus is not a match key", () -> call(area, "find", where, table("bogus", 1)));
        refuses("\"IsoNothing\" is not one of the game's object classes", () -> call(area, "find", where, table("class", list("IsoNothing"))));
        refuses("\"zombie.iso.IsoObject\" is not one of", () -> call(area, "find", where, table("class", list("zombie.iso.IsoObject"))));
        refuses("match.class must be a list of strings", () -> call(area, "find", where, table("class", list(1))));
        refuses("match.sprite must name at least one", () -> call(area, "find", where, table("sprite", list())));
        refuses("match.data must be", () -> call(area, "find", where, table("data", 3)));
        refuses("match.container must be", () -> call(area, "find", where, table("container", "yes")));
        refuses("match.noData must be", () -> call(area, "find", where, table("noData", 4)));
        refuses("options must be a table", () -> call(area, "find", where, table(), "limit"));
        refuses("options.limit must be a whole number", () -> call(area, "find", where, table(), table("limit", -1)));
        refuses("is not an option", () -> call(area, "find", where, table(), table("lmit", 1)));
        refuses("must be true or false", () -> call(area, "edges", table("room", "1"), table(), table("outer", "yes")));
    }

    /** A newer API takes the area over: the functions a mod kept refuse to be called. */
    private static void takeover(KahluaTable api) {
        var area = (KahluaTable)api.rawget("objects");
        Object kept = area.rawget("find");
        var where = box(3010, 3010, 3016, 3010, 0);
        check(items(call(area, "find", where, table())).size() == 7, "The objects are there before the takeover");
        try { GameApi.register(LuaManager.class); }
        catch (ReflectiveOperationException failure) { throw new AssertionError(failure); }
        check(area.rawget("find") != kept, "The function was not replaced");
        refuses("the API was updated", () -> FormulasTest.invoke(kept, where, table()));
        check(items(call(area, "find", where, table())).size() == 7, "The new function does not work");
    }

    // ---- cost ----

    /** What a search costs an object, and that it allocates nothing for one. */
    private static void cost(KahluaTable area) {
        int wide = 70, tall = 60;
        var doors = new ArrayList<IsoObject>();
        for (int y = 0; y < tall; y++) {
            for (int x = 0; x < wide; x++) {
                put(thing("floor_" + (x % 7)), 4000 + x, 4000 + y);
                IsoObject wall = put(thing("wall_" + (x % 5)), 4000 + x, 4000 + y);
                wall.sprite.properties.named.put("Wall", "");
                IsoObject last = (x + y) % 41 == 0 ? put(new IsoDoor(new IsoSprite("door_" + (x % 3))), 4000 + x, 4000 + y)
                    : put(new IsoThumpable(new IsoSprite("crate_" + (x % 9))), 4000 + x, 4000 + y);
                if ((x + y) % 11 == 0) mark(last, "unit", x);
                if (last instanceof IsoDoor) doors.add(last);
            }
        }
        long objects = (long)wide * tall * 3;
        var where = box(4000, 4000, 4000 + wide - 1, 4000 + tall - 1, 0);
        record Case(String name, KahluaTable match, int expected) { }
        var cases = List.of(
            new Case("class", table("class", list("IsoDoor")), doors.size()),
            new Case("class and sprite prefix", table("class", list("IsoThumpable"), "spritePrefix", list("crate_1", "crate_2")), -1),
            new Case("props and data", table("props", list("Wall"), "data", "unit"), -1),
            new Case("nothing", table("sprite", list("none"), "props", list("none")), 0),
            new Case("every object", table(), (int)objects));
        for (Case each : cases) {
            Object result = null;
            for (int warm = 0; warm < 30; warm++) result = call(area, "find", where, each.match());
            check(each.expected() < 0 || items(result).size() == each.expected(), each.name() + " found " + items(result).size() + " objects, not " + each.expected());
            int rounds = 40;
            long bytes = allocated(), start = System.nanoTime();
            for (int n = 0; n < rounds; n++) result = call(area, "find", where, each.match());
            double nanos = (System.nanoTime() - start) / (double)rounds / objects;
            bytes = (allocated() - bytes) / rounds - items(result).size() * 80L;
            System.out.printf("objects: find over %d objects, %s: %.1f ns an object, %.2f bytes an object beyond the list%n", objects, each.name(), nanos, bytes / (double)objects);
            if (each.expected() == 0) check(bytes / (double)objects < 4, "A search that finds nothing allocated " + bytes + " bytes for " + objects + " objects");
        }
        long start = System.nanoTime();
        int edgeRounds = 200;
        var tile = table("x", 4010, "y", 4010, "z", 0, "r", 12);
        for (int n = 0; n < edgeRounds; n++) call(area, "remove", tile, table("sprite", list("none")));
        System.out.printf("objects: remove that takes nothing from a circle of 12: %.1f us%n", (System.nanoTime() - start) / 1000.0 / edgeRounds);
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
