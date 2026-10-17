package pzext.api;

import java.util.ArrayList;
import java.util.List;
import pzext.boot.Hooks;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.iso.BuildingDef;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;

/**
 * {@code buildings.watchWalls} and {@code unwatchWalls}, against the synthetic game: a map building of two rooms whose walls
 * are taken down and built, the rooms they make told once at the next frame and only when they are not the building's, a
 * building waiting for its chunks, what is refused, the watches gone with their world, cancelled, cleared and taken over by a
 * newer API, and what reading a large building and the hook cost.
 */
final class WallWatchesTest {
    private static final ClassLoader GAME = WallWatchesTest.class.getClassLoader();
    private static final List<String> log = new ArrayList<>();
    /** The house: a kitchen and a living room side by side, 3 by 3 each, the wall between them on the living room's west side. */
    private static final String KEY = "200,200,0";

    private WallWatchesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        var grid = IsoWorld.instance.metaGrid;
        var made = new ArrayList<RoomDef>();
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            var buildings = (KahluaTable)api.rawget("buildings");
            check(buildings.rawget("watchWalls") != null && buildings.rawget("unwatchWalls") != null, "PZExtAPI.buildings.watchWalls is missing");
            Object mod = FormulasTest.call(api, "client", "walls.mod").get(0), second = FormulasTest.call(api, "client", "walls.second").get(0);
            house(grid, made);
            telling(buildings, mod);
            scenes(buildings, mod, grid, made);
            rectangles();
            waiting(buildings, mod);
            refusals(buildings, mod, second, grid, made);
            cancelling(buildings, mod, second);
            worldLeft(buildings, mod);
            takeover(api, mod);
            cost(buildings, mod, grid, made);
        } finally {
            grid.rooms.removeAll(made);
            IsoWorld.instance.setCell(home);
            GameApi.frame(GAME);
        }
    }

    private static void house(zombie.iso.IsoMetaGrid grid, List<RoomDef> made) {
        var house = new BuildingDef(false);
        made.add(room(grid, new RoomDef(901, "kitchen", 0, house), 200, 200, 3, 3));
        made.add(room(grid, new RoomDef(902, "livingroom", 0, house), 203, 200, 3, 3));
        loadHouse();
    }

    /** The house's squares in the cell the test has now, the wall between its rooms standing. */
    private static void loadHouse() {
        for (int x = 199; x <= 206; x++) for (int y = 199; y <= 203; y++) IsoWorld.instance.currentCell.load(x, y, 0);
        for (int y = 200; y <= 202; y++) square(203, y).westWall = true;
    }

    private static RoomDef room(zombie.iso.IsoMetaGrid grid, RoomDef room, int x, int y, int w, int h) {
        room.rects.add(new RoomDef.RoomRect(x, y, w, h));
        grid.rooms.add(room);
        return room;
    }

    private static IsoGridSquare square(int x, int y) { return IsoWorld.instance.currentCell.getGridSquare(x, y, 0); }

    /** The west walls of a column of the house's squares, set and told to the game as it would (the square's properties again). */
    private static void westWalls(int x, boolean standing) {
        for (int y = 200; y <= 202; y++) {
            IsoGridSquare at = square(x, y);
            at.westWall = standing;
            at.RecalcProperties();
        }
    }

    /** The function: what it was told, as "key: level x,y,w,h; ..." with the rooms in their order. */
    private static JavaFunction record(String name) {
        return (frame, count) -> {
            var text = new StringBuilder(name).append(' ').append(frame.get(0)).append(':');
            var rooms = (KahluaTable)frame.get(1);
            for (int index = 1; index <= rooms.len(); index++) {
                var room = (KahluaTable)rooms.rawget((double)index);
                text.append(' ').append(((Double)room.rawget("level")).intValue());
                var rects = (KahluaTable)room.rawget("rects");
                for (int at = 1; at <= rects.len(); at++) {
                    var rect = (KahluaTable)rects.rawget((double)at);
                    text.append(' ').append(number(rect, "x")).append(',').append(number(rect, "y")).append(',')
                        .append(number(rect, "w")).append(',').append(number(rect, "h"));
                }
                text.append(';');
            }
            log.add(text.toString());
            return 0;
        };
    }

    private static int number(KahluaTable table, String key) { return ((Double)table.rawget(key)).intValue(); }

    private static List<Object> watch(KahluaTable buildings, Object mod, String key, JavaFunction function) {
        return FormulasTest.call(buildings, "watchWalls", mod, key, function);
    }

    private static double id(List<Object> result) {
        check(result.get(0) instanceof Double, "No id was given: " + result);
        return (Double)result.get(0);
    }

    private static void frame() { GameApi.frame(GAME); }

    /**
     * The wall between the rooms taken down: one room, told once at the next frame. Built again where the rooms already part:
     * nothing. A wall built across the kitchen: three rooms. A change of no wall: nothing.
     */
    private static void telling(KahluaTable buildings, Object mod) {
        log.clear();
        double id = id(watch(buildings, mod, KEY, record("w")));
        check(GameApi.walls().ready() == 1, "The loaded house's walls were not read at once");
        frame();
        check(log.isEmpty(), "Rooms were told without a change: " + log);
        westWalls(203, false);
        check(log.isEmpty(), "A change was told at once, not from the frame job");
        frame();
        check(log.equals(List.of("w 200,200,0: 0 200,200,6,3;")), "The open wall did not make one room: " + log);
        frame();
        check(log.size() == 1, "The rooms were told again: " + log);
        westWalls(203, true);
        frame();
        check(log.size() == 1, "A wall built where the rooms already part was told: " + log);
        westWalls(201, true);
        frame();
        check(log.size() == 2 && log.get(1).equals("w 200,200,0: 0 200,200,1,3; 0 201,200,2,3; 0 203,200,3,3;"),
            "The wall across the kitchen did not make it two rooms: " + log);
        square(204, 201).RecalcProperties();
        frame();
        check(log.size() == 2, "A square whose walls stayed was told: " + log);
        westWalls(201, false);
        frame();
        check(FormulasTest.call(buildings, "unwatchWalls", mod, id).get(0) == Boolean.TRUE, "The watch could not be cancelled");
        log.clear();
    }

    /** Squares of the cell the test has now, on a level: x0..x1, y0..y1. */
    private static void load(int x0, int y0, int x1, int y1, int z) {
        for (int x = x0; x <= x1; x++) for (int y = y0; y <= y1; y++) IsoWorld.instance.currentCell.load(x, y, z);
    }

    private static void wall(int x, int y, int z, boolean north, boolean standing) {
        IsoGridSquare at = IsoWorld.instance.currentCell.getGridSquare(x, y, z);
        if (north) at.northWall = standing; else at.westWall = standing;
        at.RecalcProperties();
    }

    /**
     * What the map has stays: two rooms open to each other stay two, whatever is built between them; a room with a wall of its
     * own stays one, and a new wall cuts it; a wall taken down between rooms stacked north and south makes them one, the
     * floor above kept as it is.
     */
    private static void scenes(KahluaTable buildings, Object mod, zombie.iso.IsoMetaGrid grid, List<RoomDef> made) {
        log.clear();
        var open = new BuildingDef(false);
        made.add(room(grid, new RoomDef(921, "kitchen", 0, open), 500, 500, 3, 3));
        made.add(room(grid, new RoomDef(922, "livingroom", 0, open), 503, 500, 3, 3));
        load(499, 499, 506, 503, 0);
        double id = id(watch(buildings, mod, "500,500,0", record("open")));
        wall(503, 501, 0, false, true);
        frame();
        check(log.isEmpty(), "A wall built between rooms open on the map was told: " + log);
        FormulasTest.call(buildings, "unwatchWalls", mod, id);

        var hall = new BuildingDef(false);
        made.add(room(grid, new RoomDef(923, "hall", 0, hall), 600, 600, 6, 1));
        load(599, 599, 606, 601, 0);
        IsoWorld.instance.currentCell.getGridSquare(603, 600, 0).westWall = true;
        id = id(watch(buildings, mod, "600,600,0", record("hall")));
        IsoWorld.instance.currentCell.getGridSquare(603, 600, 0).RecalcProperties();
        frame();
        check(log.isEmpty(), "The map's own wall in a room was told: " + log);
        wall(601, 600, 0, false, true);
        frame();
        check(log.equals(List.of("hall 600,600,0: 0 600,600,1,1; 0 601,600,5,1;")), "A new wall did not cut the hall, or the map's own did: " + log);
        FormulasTest.call(buildings, "unwatchWalls", mod, id);

        log.clear();
        var stacked = new BuildingDef(false);
        made.add(room(grid, new RoomDef(924, "bedroom", 0, stacked), 700, 700, 2, 2));
        made.add(room(grid, new RoomDef(925, "bathroom", 0, stacked), 700, 702, 2, 2));
        made.add(room(grid, new RoomDef(926, "attic", 1, stacked), 700, 700, 2, 4));
        load(699, 699, 702, 704, 0);
        load(699, 699, 702, 704, 1);
        for (int x = 700; x <= 701; x++) IsoWorld.instance.currentCell.getGridSquare(x, 702, 0).northWall = true;
        id = id(watch(buildings, mod, "700,700,0", record("stacked")));
        wall(700, 702, 0, true, false);
        wall(701, 702, 0, true, false);
        frame();
        check(log.equals(List.of("stacked 700,700,0: 0 700,700,2,4; 1 700,700,2,4;")), "The rooms stacked north and south were not made one: " + log);
        FormulasTest.call(buildings, "unwatchWalls", mod, id);
        log.clear();
    }

    /** Squares made rectangles: runs along x, grown down while the next row has the same run; an L in three. */
    private static void rectangles() {
        int[][] squares = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 0, 2 }, { 1, 2 } };
        long[] places = new long[squares.length];
        for (int at = 0; at < squares.length; at++) places[at] = (long)squares[at][1] << 32 | squares[at][0];
        java.util.Arrays.sort(places);
        var seen = new ArrayList<String>();
        for (int[] rect : WallWatches.rects(places, 0, places.length)) seen.add(rect[0] + "," + rect[1] + "," + rect[2] + "," + rect[3]);
        check(String.join(" ", seen).equals("0,0,3,1 0,1,1,1 0,2,2,1"), "The L was not three rectangles: " + seen);
        long[] block = new long[6];
        for (int at = 0; at < 6; at++) block[at] = (long)(at / 3) << 32 | at % 3;
        check(WallWatches.rects(block, 0, 6).size() == 1 && WallWatches.rects(block, 0, 6).get(0)[3] == 2, "A block was not one rectangle");
    }

    /** A house with a chunk not loaded: the watch waits, and reads the walls as they are once it is; what changed before is not told. */
    private static void waiting(KahluaTable buildings, Object mod) {
        log.clear();
        var chunk = square(203, 200).chunk;
        chunk.loaded = false;
        double id = id(watch(buildings, mod, KEY, record("wait")));
        check(GameApi.walls().ready() == 0, "A watch read the walls of a chunk not loaded");
        westWalls(203, false);
        frame();
        check(log.isEmpty(), "A waiting watch told rooms: " + log);
        chunk.loaded = true;
        for (int n = 0; n < WallWatches.WAIT_FRAMES + 1; n++) frame();
        check(GameApi.walls().ready() == 1 && log.isEmpty(), "The watch did not read the walls once loaded, or told the change before: " + log);
        westWalls(203, true);
        frame();
        check(log.isEmpty(), "The rooms the walls make again were told: " + log);
        FormulasTest.call(buildings, "unwatchWalls", mod, id);
    }

    /** No building, one players built, one wider than the game loads; and the arguments and the limits. */
    private static void refusals(KahluaTable buildings, Object mod, Object second, zombie.iso.IsoMetaGrid grid, List<RoomDef> made) {
        check(watch(buildings, mod, "1,1,0", record("x")).equals(java.util.Arrays.asList(null, "no building has that key")),
            "A key of no building was taken");
        var built = new BuildingDef(true);
        made.add(room(grid, new RoomDef(903, "shed", 0, built), 300, 300, 2, 2));
        check("the game remakes the rooms of a building players built".equals(watch(buildings, mod, "300,300,0", record("x")).get(1)),
            "A building players built was taken");
        var wide = new BuildingDef(false);
        made.add(room(grid, new RoomDef(904, "warehouse", 0, wide), 400, 400, 97, 2));
        check("the building is larger than the game loads at once".equals(watch(buildings, mod, "400,400,0", record("x")).get(1)),
            "A building wider than the game loads was taken");
        var tall = new BuildingDef(false);
        for (int z = 0; z < 5; z++) made.add(room(grid, new RoomDef(905 + z, "tower", z, tall), 1500, 1500, 90, 80));
        check(String.valueOf(watch(buildings, mod, "1500,1500,0", record("x")).get(1)).contains("more than 32768 squares"),
            "A building of more squares than a watch holds was taken");
        rejects(buildings, "handle", () -> FormulasTest.call(buildings, "watchWalls", "nobody", KEY, record("x")));
        rejects(buildings, "function", () -> FormulasTest.call(buildings, "watchWalls", mod, KEY, "not a function"));
        rejects(buildings, "id", () -> FormulasTest.call(buildings, "unwatchWalls", mod, "1"));
        var ids = new ArrayList<Double>();
        for (int n = 0; n < WallWatches.MAX_PER_MOD; n++) ids.add(id(watch(buildings, mod, KEY, record("x"))));
        rejects(buildings, "at most", () -> watch(buildings, mod, KEY, record("x")));
        for (double id : ids) FormulasTest.call(buildings, "unwatchWalls", mod, id);
        check(GameApi.walls().count() == 0, "Watches were left: " + GameApi.walls().count());
    }

    /** Another mod cannot cancel a watch; a cancelled or cleared one is not told, and lets the hook go with the last. */
    private static void cancelling(KahluaTable buildings, Object mod, Object second) {
        log.clear();
        double id = id(watch(buildings, mod, KEY, record("c")));
        check(FormulasTest.call(buildings, "unwatchWalls", second, id).get(0) == Boolean.FALSE, "Another mod cancelled the watch");
        check(FormulasTest.call(buildings, "unwatchWalls", mod, id).get(0) == Boolean.TRUE, "The watch could not be cancelled");
        westWalls(203, false);
        frame();
        check(log.isEmpty(), "A cancelled watch was told: " + log);
        westWalls(203, true);
        frame();
        id(watch(buildings, mod, KEY, record("c")));
        FormulasTest.call(mod, "clear");
        check(GameApi.walls().count() == 0 && GameApi.walls().ready() == 0, "The watch outlived clear");
        westWalls(203, false);
        frame();
        check(log.isEmpty(), "A cleared watch was told: " + log);
        westWalls(203, true);
        frame();
    }

    private static void worldLeft(KahluaTable buildings, Object mod) {
        log.clear();
        id(watch(buildings, mod, KEY, record("old")));
        check(GameApi.walls().count() == 1, "The watch is not there");
        IsoWorld.instance.setCell(new IsoCell());
        frame();
        check(GameApi.walls().count() == 0, "A watch outlived its world");
        loadHouse();
        frame();
    }

    /** A newer API takes the watches over and reads their walls again; a function a mod kept refuses to be called. */
    private static void takeover(KahluaTable api, Object mod) throws Exception {
        var buildings = (KahluaTable)api.rawget("buildings");
        log.clear();
        double id = id(watch(buildings, mod, KEY, record("kept")));
        Object oldWatch = buildings.rawget("watchWalls");
        GameApi.register(LuaManager.class);
        var next = GameApi.walls();
        check(buildings.rawget("watchWalls") != oldWatch && next.count() == 1, "The watch was not taken over");
        try {
            ((JavaFunction)oldWatch).call(new LuaCallFrame(mod, KEY, record("x")), 3);
            throw new AssertionError("an old function worked");
        } catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        frame();
        check(next.ready() == 1, "The watch taken over did not read its walls");
        westWalls(203, false);
        frame();
        check(log.equals(List.of("kept 200,200,0: 0 200,200,6,3;")), "The watch did not go on after the takeover: " + log);
        westWalls(203, true);
        frame();
        check(FormulasTest.call(buildings, "unwatchWalls", mod, id).get(0) == Boolean.TRUE, "The watch cannot be cancelled after the takeover");
        log.clear();
    }

    /**
     * What a large building costs: its walls read (90 by 90 squares on four floors, 32400), a wall taken down in it worked out,
     * and the hook with a square of it and one elsewhere; printed, and the hook allocates nothing.
     */
    private static void cost(KahluaTable buildings, Object mod, zombie.iso.IsoMetaGrid grid, List<RoomDef> made) {
        log.clear();
        var hall = new BuildingDef(false);
        for (int z = 0; z < 4; z++) {
            made.add(room(grid, new RoomDef(910 + 2 * z, "hall", z, hall), 1000, 1000, 45, 90));
            made.add(room(grid, new RoomDef(911 + 2 * z, "hall", z, hall), 1045, 1000, 45, 90));
            for (int x = 1000; x < 1090; x++) for (int y = 1000; y < 1090; y++) IsoWorld.instance.currentCell.load(x, y, z);
            for (int y = 1000; y < 1090; y++) IsoWorld.instance.currentCell.getGridSquare(1045, y, z).westWall = true;
        }
        long start = System.nanoTime();
        double id = id(watch(buildings, mod, "1000,1000,0", record("hall")));
        double read = (System.nanoTime() - start) / 1e6;
        check(GameApi.walls().ready() == 1, "The hall's walls were not read");
        for (int y = 1000; y < 1090; y++) {
            IsoGridSquare at = IsoWorld.instance.currentCell.getGridSquare(1045, y, 2);
            at.westWall = false;
            at.RecalcProperties();
        }
        start = System.nanoTime();
        frame();
        double worked = (System.nanoTime() - start) / 1e6;
        check(log.size() == 1 && log.get(0).contains(" 2 1000,1000,90,90;"), "The open wall in the hall was not told: " + log);
        int rounds = 2_000_000;
        for (int warm = 0; warm < rounds; warm++) Hooks.squareChanged(1000 + (warm & 63), 1000 + (warm & 31), 0);
        long bytes = allocated();
        start = System.nanoTime();
        for (int n = 0; n < rounds; n++) Hooks.squareChanged(1000 + (n & 63), 1000 + (n & 31), 0);
        double inside = (System.nanoTime() - start) / (double)rounds;
        long insideBytes = allocated() - bytes;
        bytes = allocated();
        start = System.nanoTime();
        for (int n = 0; n < rounds; n++) Hooks.squareChanged(5000 + (n & 63), 5000 + (n & 31), 0);
        double outside = (System.nanoTime() - start) / (double)rounds;
        long outsideBytes = allocated() - bytes;
        frame();
        System.out.printf("walls: a building of 32400 squares read in %.1f ms, a wall taken down worked out in %.1f ms; "
            + "a square change costs %.1f ns in it (marked once), %.1f ns elsewhere%n", read, worked, inside, outside);
        check(insideBytes < 64 * 1024 && outsideBytes < 1024, "The hook allocated: " + insideBytes + ", " + outsideBytes + " bytes");
        FormulasTest.call(buildings, "unwatchWalls", mod, id);
        log.clear();
    }

    private static void rejects(KahluaTable buildings, String message, Runnable call) {
        try { call.run(); }
        catch (RuntimeException thrown) {
            if (String.valueOf(thrown.getMessage()).contains(message)) return;
            throw new AssertionError("failed otherwise than \"" + message + "\": " + thrown.getMessage(), thrown);
        }
        throw new AssertionError("a bad call was taken: " + message);
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
