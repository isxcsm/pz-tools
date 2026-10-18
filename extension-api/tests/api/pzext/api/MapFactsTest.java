package pzext.api;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.PriorityQueue;
import java.util.Set;
import java.util.SplittableRandom;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;
import zombie.core.stash.StashSystem;
import zombie.iso.BuildingDef;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoMetaGrid;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.iso.areas.IsoBuilding;
import zombie.iso.zones.Zone;
import zombie.vehicles.BaseVehicle;

/**
 * The map facts (docs/design.md, "Map facts" and "Squares"), against the synthetic game: {@code buildings.list} (the ring, the filters,
 * what is kept and what is asked live), {@code zones.points}, {@code vehicles.near} and {@code squares.path} (checked against a plain
 * Dijkstra over states on random fields), and what each costs.
 */
final class MapFactsTest {
    private static final ClassLoader GAME = MapFactsTest.class.getClassLoader();
    private static long roomIds = 7_000_000;

    private MapFactsTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        IsoMetaGrid grid = IsoWorld.instance.metaGrid;
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            check(((KahluaTable)api.rawget("buildings")).rawget("list") != null, "buildings.list is missing");
            check(api.rawget("zones") != null && api.rawget("vehicles") != null, "PZExtAPI.zones or PZExtAPI.vehicles is missing");
            check(((KahluaTable)api.rawget("squares")).rawget("path") != null && ((KahluaTable)api.rawget("squares")).rawget("watch") != null,
                "squares.path or squares.watch is missing");
            lists((KahluaTable)api.rawget("buildings"), grid);
            points((KahluaTable)api.rawget("zones"), grid);
            vehicles((KahluaTable)api.rawget("vehicles"));
            paths((KahluaTable)api.rawget("squares"), grid);
            takeover(api);
        } finally {
            IsoWorld.instance.setCell(home);
            GameApi.frame(GAME);
        }
    }

    // ---- helpers ----

    private static KahluaTable table(Object... pairs) {
        var result = new KahluaTableImpl();
        for (int at = 0; at < pairs.length; at += 2) result.rawset(pairs[at], pairs[at + 1] instanceof Integer n ? (Object)(double)n : pairs[at + 1]);
        return result;
    }

    private static KahluaTable list(Object... values) {
        var result = new KahluaTableImpl();
        for (int at = 0; at < values.length; at++) result.rawset((Object)(double)(at + 1), values[at] instanceof Integer n ? (Object)(double)n : values[at]);
        return result;
    }

    private static List<Object> items(Object table) {
        var kahlua = (KahluaTable)table;
        var result = new ArrayList<Object>();
        for (int at = 1; at <= kahlua.len(); at++) result.add(kahlua.rawget((double)at));
        return result;
    }

    private static double number(Object table, String key) { return (Double)((KahluaTable)table).rawget(key); }

    private static void rejects(String message, KahluaTable area, String name, Object... arguments) {
        try {
            FormulasTest.call(area, name, arguments);
            throw new AssertionError(name + " took " + java.util.Arrays.toString(arguments));
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message), expected.getMessage());
        }
    }

    private static RoomDef room(IsoMetaGrid grid, BuildingDef building, String name, int level, int x, int y, int w, int h) {
        var room = new RoomDef(roomIds++, name, level, building);
        room.rects.add(new RoomDef.RoomRect(x, y, w, h));
        grid.rooms.add(room);
        return room;
    }

    private static void forget(IsoMetaGrid grid, BuildingDef... defs) {
        for (BuildingDef def : defs) {
            grid.buildings.remove(def);
            grid.rooms.removeAll(def.rooms);
        }
    }

    // ---- buildings.list ----

    private static void lists(KahluaTable buildings, IsoMetaGrid grid) {
        var kitchen = new BuildingDef(false);
        room(grid, kitchen, "kitchen", 0, 50000, 50000, 10, 6);
        room(grid, kitchen, "bedroom", 1, 50000, 50000, 10, 4);
        var shed = new BuildingDef(false);
        room(grid, shed, "shed", 0, 50030, 50000, 4, 4);
        var cellar = new BuildingDef(false);
        room(grid, cellar, "cellar", -1, 50040, 50000, 8, 8);
        var built = new BuildingDef(true);
        room(grid, built, "", 0, 50060, 50000, 6, 6);
        var seen = new BuildingDef(false);
        room(grid, seen, "store", 0, 50080, 50000, 10, 10);
        seen.hasBeenVisited = true;
        var stashed = new BuildingDef(false);
        room(grid, stashed, "house", 0, 50100, 50000, 10, 10);
        StashSystem.stashes.add(stashed);
        var empty = new BuildingDef(false);
        BuildingDef[] all = { kitchen, shed, cellar, built, seen, stashed, empty };
        for (BuildingDef def : all) grid.buildings.add(def);
        try {
            var every = items(FormulasTest.call(buildings, "list", 50005.0, 50003.0, 0.0, 1000.0).get(0));
            check(every.size() == 6, "Not every building was listed (the one without rooms is none): " + every.size());
            KahluaTable first = null;
            for (Object found : every) if (((KahluaTable)found).rawget("key").equals("50000,50000,0")) first = (KahluaTable)found;
            check(first != null && number(first, "x") == 50005 && number(first, "y") == 50003 && number(first, "distance") == 0
                && number(first, "area") == 100 && number(first, "minX") == 50000 && number(first, "maxX") == 50009
                && number(first, "minY") == 50000 && number(first, "maxY") == 50005 && number(first, "minLevel") == 0
                && number(first, "maxLevel") == 1 && first.rawget("roomNames") == null, "The building was misdescribed");
            // The ring: the middle's distance from the point.
            var ring = keys(buildings, 50005, 50003, 20, 45, null);
            check(ring.equals(Set.of("50030,50000,0", "50040,50000,-1")), "The ring is wrong: " + ring);
            // The filters.
            check(keys(buildings, 50005, 50003, 0, 1000, table("minArea", 30)).size() == 5, "minArea 30 should leave out the shed");
            check(!keys(buildings, 50005, 50003, 0, 1000, table("basement", false)).contains("50040,50000,-1")
                && keys(buildings, 50005, 50003, 0, 1000, table("basement", true)).equals(Set.of("50040,50000,-1")), "basement is wrong");
            check(!keys(buildings, 50005, 50003, 0, 1000, table("playerBuilt", false)).contains("50060,50000,0")
                && keys(buildings, 50005, 50003, 0, 1000, table("playerBuilt", true)).equals(Set.of("50060,50000,0")), "playerBuilt is wrong");
            check(!keys(buildings, 50005, 50003, 0, 1000, table("visited", false)).contains("50080,50000,0"), "visited = false left a visited one");
            check(!keys(buildings, 50005, 50003, 0, 1000, table("stash", false)).contains("50100,50000,0"), "stash = false left a stash");
            check(keys(buildings, 50005, 50003, 0, 1000, table("stash", true)).equals(Set.of("50100,50000,0")), "stash = true is wrong");
            var plain = keys(buildings, 50005, 50003, 0, 1000, table("minArea", 30, "basement", false, "playerBuilt", false, "visited", false, "stash", false));
            check(plain.equals(Set.of("50000,50000,0")), "The filters together are wrong: " + plain);
            var named = items(FormulasTest.call(buildings, "list", 50005.0, 50003.0, 0.0, 10.0, table("roomNames", true)).get(0));
            var names = items(((KahluaTable)named.get(0)).rawget("roomNames"));
            check(named.size() == 1 && names.size() == 2 && names.contains("kitchen") && names.contains("bedroom"), "The rooms' names are wrong: " + names);
            // What is kept: a second call does not ask the definition's rooms again. What is live: a building visited later.
            int asked = kitchen.asked;
            keys(buildings, 50005, 50003, 0, 1000, null);
            check(kitchen.asked == asked, "The rooms of a map building were asked for again");
            kitchen.hasBeenVisited = true;
            check(!keys(buildings, 50005, 50003, 0, 1000, table("visited", false)).contains("50000,50000,0"), "A building visited since was listed");
            kitchen.hasBeenVisited = false;
            StashSystem.stashes.add(kitchen);
            check(!keys(buildings, 50005, 50003, 0, 1000, table("stash", false)).contains("50000,50000,0"), "A stash made since was listed");
            StashSystem.stashes.remove(kitchen);
            // A building made later is listed; new rooms (the world's building edits) are described anew.
            var later = new BuildingDef(false);
            room(grid, later, "later", 0, 50200, 50000, 10, 10);
            grid.buildings.add(later);
            check(keys(buildings, 50005, 50003, 0, 1000, null).contains("50200,50000,0"), "A new building was not listed");
            kitchen.rooms.get(0).rects.get(0).w = 20;
            GameApi.buildings().changed();
            var wider = items(FormulasTest.call(buildings, "list", 50005.0, 50003.0, 0.0, 5.0).get(0));
            check(wider.size() == 1 && number(wider.get(0), "maxX") == 50019 && number(wider.get(0), "x") == 50010, "New rooms were not read again");
            forget(grid, later);
            // Mistakes.
            rejects("lo must not be more than hi", buildings, "list", 0.0, 0.0, 5.0, 1.0);
            rejects("x must be a number", buildings, "list", "a", 0.0, 0.0, 1.0);
            rejects("filter must be a table", buildings, "list", 0.0, 0.0, 0.0, 1.0, "x");
            rejects("filter.minArea must be a number", buildings, "list", 0.0, 0.0, 0.0, 1.0, table("minArea", "x"));
            rejects("filter.stash must be true or false", buildings, "list", 0.0, 0.0, 0.0, 1.0, table("stash", 1));
            listCost(buildings, grid);
        } finally {
            StashSystem.stashes.clear();
            forget(grid, all);
            GameApi.buildings().changed();
        }
    }

    private static Set<String> keys(KahluaTable buildings, double x, double y, double lo, double hi, KahluaTable filter) {
        var result = new HashSet<String>();
        var found = filter == null ? FormulasTest.call(buildings, "list", x, y, lo, hi) : FormulasTest.call(buildings, "list", x, y, lo, hi, filter);
        for (Object each : items(found.get(0))) result.add((String)((KahluaTable)each).rawget("key"));
        return result;
    }

    /** A map of several thousand buildings: the first call describes them, the next ones only look. */
    private static void listCost(KahluaTable buildings, IsoMetaGrid grid) {
        var many = new ArrayList<BuildingDef>();
        for (int at = 0; at < 6000; at++) {
            var def = new BuildingDef(false);
            int x = 80000 + at % 100 * 20, y = 80000 + at / 100 * 20;
            var room = new RoomDef(roomIds++, at % 7 == 0 ? "bedroom" : "kitchen", 0, def);
            room.rects.add(new RoomDef.RoomRect(x, y, 8, 8));
            var second = new RoomDef(roomIds++, "bathroom", 0, def);
            second.rects.add(new RoomDef.RoomRect(x + 8, y, 4, 4));
            many.add(def);
        }
        grid.buildings.addAll(many);
        try {
            var filter = table("minArea", 30, "basement", false, "playerBuilt", false, "visited", false, "stash", false);
            // The first call describes every building (and keeps them); a small ring so that no result table is made on the way.
            long start = System.nanoTime();
            FormulasTest.call(buildings, "list", 81000.0, 80600.0, 0.0, 30.0, filter);
            long firstTime = System.nanoTime() - start;
            // A ring that a mod picks a site from: a few hundred buildings.
            start = System.nanoTime();
            var ring = items(FormulasTest.call(buildings, "list", 81000.0, 80600.0, 200.0, 400.0, filter).get(0));
            long ringCold = System.nanoTime() - start;
            long ringBest = Long.MAX_VALUE;
            for (int round = 0; round < 30; round++) {
                start = System.nanoTime();
                FormulasTest.call(buildings, "list", 81000.0, 80600.0, 200.0, 400.0, filter);
                ringBest = Math.min(ringBest, System.nanoTime() - start);
            }
            // Most of the map, all the tables made: the worst a call can ask.
            start = System.nanoTime();
            var first = items(FormulasTest.call(buildings, "list", 81000.0, 80600.0, 100.0, 900.0, filter).get(0));
            long bigCold = System.nanoTime() - start;
            long best = Long.MAX_VALUE;
            for (int round = 0; round < 30; round++) {
                start = System.nanoTime();
                FormulasTest.call(buildings, "list", 81000.0, 80600.0, 100.0, 900.0, filter);
                best = Math.min(best, System.nanoTime() - start);
            }
            start = System.nanoTime();
            var named = items(FormulasTest.call(buildings, "list", 81000.0, 80600.0, 100.0, 900.0, table("roomNames", true)).get(0));
            long namesTime = System.nanoTime() - start;
            check(first.size() > 100 && first.size() == named.size() && ring.size() > 20 && ring.size() < first.size(),
                "The ring of the many buildings was wrong: " + first.size() + " " + ring.size());
            System.out.println("COST: buildings.list over 6000 buildings: first call (describes them all) " + firstTime / 1000 + " us; a ring of "
                + ring.size() + ": first " + ringCold / 1000 + " us, kept " + ringBest / 1000 + " us; " + first.size() + " listed: first " + bigCold / 1000
                + " us, kept " + best / 1000 + " us; with room names (first) " + namesTime / 1000 + " us");
            check(best < 20_000_000L, "buildings.list took " + best / 1000 + " us over 6000 buildings once kept");
        } finally {
            forget(grid, many.toArray(new BuildingDef[0]));
            GameApi.buildings().changed();
        }
    }

    // ---- zones.points ----

    private static boolean zoneAt(IsoMetaGrid grid, String type, int x, int y) {
        for (Zone zone : grid.zones) if (zone.type.equals(type) && x >= zone.x && x < zone.x + zone.w && y >= zone.y && y < zone.y + zone.h) return true;
        return false;
    }

    private static final double[][] DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } };

    private static boolean roadAround(IsoMetaGrid grid, String type, int x, int y, int radius) {
        for (double[] d : DIRECTIONS) if (zoneAt(grid, type, (int)Math.floor(x + d[0] * radius), (int)Math.floor(y + d[1] * radius))) return true;
        return false;
    }

    private static void points(KahluaTable zones, IsoMetaGrid grid) {
        var hut = new BuildingDef(false);
        room(grid, hut, "hut", 0, 60014, 59990, 8, 20);
        grid.buildings.add(hut);
        grid.zones.add(new Zone("", "Vegitation", 59000, 59000, 0, 2000, 2000));
        grid.zones.add(new Zone("", "TownZone", 60000, 59000, 0, 2000, 2000));
        grid.zones.add(new Zone("", "Trail", 60020, 59000, 0, 5, 2000));
        grid.zones.add(new Zone("", "Nav", 60040, 59000, 0, 5, 2000));
        Zones.random = new SplittableRandom(7);
        try {
            var all = items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0, table("count", 40, "tries", 2000)).get(0));
            check(all.size() == 40, "Not as many points as asked for were kept: " + all.size());
            boolean east = false;
            for (Object each : all) {
                double dx = number(each, "x") - 60000, dy = number(each, "y") - 60000, d = Math.sqrt(dx * dx + dy * dy);
                check(d >= 9 && d <= 31, "A point is off the ring: " + d);
                check(grid.getBuildingAt((int)number(each, "x"), (int)number(each, "y")) == null, "A point is in a building");
                var types = new HashSet<Object>(items(((KahluaTable)each).rawget("zones")));
                check(types.contains("Vegitation"), "A point's zones were not given: " + types);
                east |= types.contains("TownZone");
            }
            check(east, "The test field has no point in the town zone to leave out");
            // Not in a zone type; the count; spacing.
            var west = items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0,
                table("count", 15, "tries", 2000, "not", list("TownZone", "Other"))).get(0));
            check(west.size() == 15, "Points not in the town zone were not found");
            for (Object each : west) check(number(each, "x") < 60000 && !items(((KahluaTable)each).rawget("zones")).contains("TownZone"), "A point is in a zone left out");
            var spaced = items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0, table("count", 100, "tries", 2000, "spacing", 12)).get(0));
            check(spaced.size() > 3 && spaced.size() < 100, "Spaced points: " + spaced.size());
            for (int a = 0; a < spaced.size(); a++) for (int b = a + 1; b < spaced.size(); b++)
                check(Math.hypot(number(spaced.get(a), "x") - number(spaced.get(b), "x"), number(spaced.get(a), "y") - number(spaced.get(b), "y")) >= 12,
                    "Two points are nearer than the spacing");
            check(items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0, table("count", 5, "tries", 1)).get(0)).size() <= 1, "tries was not kept to");
            check(items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0, table("count", 1)).get(0)).size() == 1, "A default count of tries finds one");
            // Roads: none of the type within 8 (looked for every 4 on eight directions), and one within 40 further out.
            var road = items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0,
                table("count", 50, "tries", 4000, "road", table("type", "Nav", "none", 8, "some", 40))).get(0));
            check(road.size() > 5, "Points by a road were not found: " + road.size());
            for (Object each : road) {
                int x = (int)number(each, "x"), y = (int)number(each, "y");
                check(!roadAround(grid, "Nav", x, y, 4) && !roadAround(grid, "Nav", x, y, 8), "A road lies within 8 of a point");
                boolean some = false;
                for (int r = 12; r <= 40; r += 4) some |= roadAround(grid, "Nav", x, y, r);
                check(some, "No road lies within 40 of the point " + x + "," + y);
            }
            boolean far = false;
            for (Object each : all) far |= number(each, "x") < 59985;
            check(far, "The field has no point too far from the road to leave out");
            var trail = items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0,
                table("count", 200, "tries", 4000, "road", table("type", "Trail", "none", 8))).get(0));
            for (Object each : trail) {
                int x = (int)number(each, "x"), y = (int)number(each, "y");
                check(!roadAround(grid, "Trail", x, y, 4) && !roadAround(grid, "Trail", x, y, 8), "A trail lies within 8 of a point");
            }
            boolean near = false;
            for (Object each : items(FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 30.0, table("count", 200, "tries", 4000)).get(0)))
                near |= roadAround(grid, "Trail", (int)number(each, "x"), (int)number(each, "y"), 4)
                    || roadAround(grid, "Trail", (int)number(each, "x"), (int)number(each, "y"), 8);
            check(trail.size() > 5 && near, "The trail test is empty");
            // Mistakes.
            rejects("options must be a table", zones, "points", 0.0, 0.0, 0.0, 1.0);
            rejects("options.count must be a whole number from 1 to 1000", zones, "points", 0.0, 0.0, 0.0, 1.0, table("count", 0));
            rejects("options.tries must be a whole number", zones, "points", 0.0, 0.0, 0.0, 1.0, table("tries", 0.5));
            rejects("options.not must be a list", zones, "points", 0.0, 0.0, 0.0, 1.0, table("not", "x"));
            rejects("options.road must be a table with the zone type", zones, "points", 0.0, 0.0, 0.0, 1.0, table("road", table("none", 8)));
            rejects("options.spacing must be a number", zones, "points", 0.0, 0.0, 0.0, 1.0, table("spacing", -1));
            rejects("lo must not be more than hi", zones, "points", 0.0, 0.0, 9.0, 1.0, table("count", 1));
            pointsCost(zones, grid);
        } finally {
            Zones.random = null;
            grid.zones.clear();
            forget(grid, hut);
        }
    }

    private static void pointsCost(KahluaTable zones, IsoMetaGrid grid) {
        var many = new ArrayList<BuildingDef>();
        for (int at = 0; at < 3000; at++) {
            var def = new BuildingDef(false);
            room(grid, def, "x", 0, 40000 + at % 60 * 10, 40000 + at / 60 * 10, 6, 6);
            grid.buildings.add(def);
            many.add(def);
        }
        var options = table("count", 1, "tries", 300, "not", list("TownZone", "DeepForest"), "road", table("type", "Nav", "none", 8, "some", 40));
        try {
            long best = Long.MAX_VALUE;
            for (int round = 0; round < 20; round++) {
                long start = System.nanoTime();
                FormulasTest.call(zones, "points", 60000.0, 60000.0, 10.0, 60.0, options);
                best = Math.min(best, System.nanoTime() - start);
            }
            System.out.println("COST: zones.points, 300 tries with a road test over 3000 buildings: best " + best / 1000 + " us");
        } finally {
            forget(grid, many.toArray(new BuildingDef[0]));
        }
    }

// ---- a newer API takes the functions over ----

/** A function a mod copied out of a table refuses to run once a newer API replaced the table's functions. */
private static void takeover(KahluaTable api) throws Exception {
    var buildings = (KahluaTable)api.rawget("buildings");
    var zones = (KahluaTable)api.rawget("zones");
    var vehicles = (KahluaTable)api.rawget("vehicles");
    var squares = (KahluaTable)api.rawget("squares");
    Object[] old = { buildings.rawget("list"), zones.rawget("points"), vehicles.rawget("near"), squares.rawget("path") };
    Object[][] arguments = { { 0.0, 0.0, 0.0, 1.0 }, { 0.0, 0.0, 0.0, 1.0, table("count", 1) }, { 0.0, 0.0, 0.0, 1.0 },
        { table("x", 0, "y", 0, "z", 0), table("x", 1, "y", 0, "z", 0) } };
    for (int at = 0; at < old.length; at++) check(old[at] != null, "A function is missing before the takeover");
    for (int at = 0; at < old.length; at++) FormulasTest.invoke(old[at], arguments[at]);
    GameApi.register(LuaManager.class);
    Object[] next = { buildings.rawget("list"), zones.rawget("points"), vehicles.rawget("near"), squares.rawget("path") };
    for (int at = 0; at < old.length; at++) {
        check(next[at] != null && next[at] != old[at], "The function " + at + " was not replaced");
        try {
            ((JavaFunction)old[at]).call(new LuaCallFrame(arguments[at]), arguments[at].length);
            throw new AssertionError("an old function " + at + " worked");
        } catch (IllegalArgumentException expected) { check(expected.getMessage().contains("the API was updated"), expected.getMessage()); }
        FormulasTest.invoke(next[at], arguments[at]);
    }
    check(squares.rawget("watch") != null, "The watches were lost with the takeover");
}

// ---- vehicles.near ----

    private static BaseVehicle vehicle(float x, float y, float z) {
        var car = new BaseVehicle();
        car.x = x; car.y = y; car.z = z;
        IsoWorld.instance.currentCell.vehicles.add(car);
        return car;
    }

    private static void vehicles(KahluaTable area) {
        check(items(FormulasTest.call(area, "near", 100.0, 100.0, 0.0, 50.0).get(0)).isEmpty(), "Vehicles were found in an empty cell");
        var near = vehicle(103f, 104f, 0f);
        var nearer = vehicle(101.5f, 100f, 0.05f);
        var edge = vehicle(110f, 100f, 0f);
        var out = vehicle(110.5f, 100f, 0f);
        var above = vehicle(100f, 101f, 1f);
        var high = vehicle(100f, 101f, 2f);
        var found = items(FormulasTest.call(area, "near", 100.0, 100.0, 0.0, 10.0).get(0));
        check(found.equals(List.of(above, nearer, near, edge)), "The vehicles near were wrong or not nearest first: " + found.size());
        check(items(FormulasTest.call(area, "near", 100.0, 100.0, 2.0, 2.0).get(0)).equals(List.of(above, high)),
            "The levels one above or below were wrong");
        check(items(FormulasTest.call(area, "near", 100.0, 100.0, 5.0, 100.0).get(0)).isEmpty(), "Vehicles of another level were found");
        rejects("r must be a number", area, "near", 0.0, 0.0, 0.0, -1.0);
        rejects("z must be a whole number", area, "near", 0.0, 0.0, 0.5, 1.0);
        IsoWorld.instance.setCell(new IsoCell());
        check(items(FormulasTest.call(area, "near", 100.0, 100.0, 0.0, 50.0).get(0)).isEmpty(), "Vehicles of another cell were found");
        IsoWorld.instance.setCell(new IsoCell());
        for (int at = 0; at < 200; at++) vehicle(at, at % 17, 0f);
        long best = Long.MAX_VALUE;
        for (int round = 0; round < 50; round++) {
            long start = System.nanoTime();
            FormulasTest.call(area, "near", 100.0, 8.0, 0.0, 30.0);
            best = Math.min(best, System.nanoTime() - start);
        }
        System.out.println("COST: vehicles.near over 200 vehicles: best " + best / 1000 + " us");
    }

    // ---- squares.path ----

    private static final int BASE = 70000;

    private static IsoGridSquare square(int x, int y) { return IsoWorld.instance.currentCell.load(BASE + x, BASE + y, 0); }

    private static IsoObject floor() { return new IsoObject(null); }

    /** A field x, y in 0 up to size, loaded, with floors. */
    private static void field(int size) {
        IsoWorld.instance.setCell(new IsoCell());
        for (int x = 0; x < size; x++) for (int y = 0; y < size; y++) square(x, y).floor = floor();
    }

    private static List<Object> path(KahluaTable area, Object from, Object to, KahluaTable options) {
        return options == null ? FormulasTest.call(area, "path", from, to) : FormulasTest.call(area, "path", from, to, options);
    }

    private static int[] steps(Object table) {
        var list = (KahluaTable)table;
        int[] result = new int[list.len()];
        for (int at = 0; at < result.length; at++) result[at] = (int)(double)(Double)list.rawget((double)(at + 1)) - BASE;
        return result;
    }

    private static int turns(int[] flat) {
        int turns = 0;
        for (int at = 4; at < flat.length; at += 2) {
            if (flat[at] - flat[at - 2] != flat[at - 2] - flat[at - 4] || flat[at + 1] - flat[at - 1] != flat[at - 1] - flat[at - 3]) turns++;
        }
        return turns;
    }

    private static void paths(KahluaTable area, IsoMetaGrid grid) {
        field(30);
        // An open field: a step costs 1, a turn what the option says; a way of the squares from one to the other.
        var found = path(area, square(2, 3), square(9, 3), null);
        var flat = steps(found.get(0));
        check(flat.length == 16 && flat[0] == 2 && flat[1] == 3 && flat[14] == 9 && flat[15] == 3 && (Double)found.get(1) == 7.0,
            "A straight way was wrong: " + java.util.Arrays.toString(flat) + " " + found.get(1));
        found = path(area, square(0, 0), square(5, 5), table("cost", table("turn", 5)));
        flat = steps(found.get(0));
        check(flat.length == 22 && turns(flat) == 1 && (Double)found.get(1) == 15.0, "A turn was not charged once: " + found.get(1) + " " + turns(flat));
        // A table for an end, and the same square.
        found = path(area, table("x", BASE + 4, "y", BASE + 4, "z", 0), square(4, 4), null);
        check(steps(found.get(0)).length == 2 && (Double)found.get(1) == 0.0, "The same square has a way of itself");
        check(path(area, square(1, 1), table("x", BASE + 1, "y", BASE + 1, "z", 1), null).get(0) == null, "A way was found between levels");
        // A wall between two squares: a step the game blocks pays blocked, so the way goes through the gap when it is cheaper.
        for (int y = 0; y < 12; y++) if (y != 9) square(5, y).westWall = true;
        found = path(area, square(2, 6), square(8, 6), table("cost", table("blocked", 100), "margin", 3));
        flat = steps(found.get(0));
        boolean gap = false;
        for (int at = 0; at < flat.length; at += 2) gap |= flat[at] == 5 && flat[at + 1] == 9;
        check(gap && (Double)found.get(1) == 12.0, "The way did not use the gap: " + found.get(1));
        found = path(area, square(2, 6), square(8, 6), table("cost", table("blocked", 3), "margin", 3));
        check((Double)found.get(1) == 9.0 && steps(found.get(0)).length == 14, "A wall dearer than a step was crossed or not: " + found.get(1));
        found = path(area, square(2, 6), square(8, 6), table("cost", table("blocked", Double.POSITIVE_INFINITY), "margin", 3));
        check((Double)found.get(1) == 12.0, "A wall that may not be crossed was: " + found.get(1));
        for (int y = 0; y < 12; y++) square(5, y).westWall = false;
        // The filter: squares without a floor are not walked on, but the two ends are not asked.
        for (int x = 0; x < 30; x++) square(x, 10).floor = null;
        for (int x = 20; x < 30; x++) square(x, 10).floor = floor();
        found = path(area, square(5, 8), square(5, 12), table("pass", table("floor", true), "margin", 20));
        flat = steps(found.get(0));
        check(found.get(0) != null, "The way did not go round");
        boolean crossed = false;
        for (int at = 0; at < flat.length; at += 2) crossed |= flat[at + 1] == 10 && flat[at] >= 0 && flat[at] < 20;
        check(!crossed, "The way crossed squares without a floor");
        check(path(area, square(5, 8), square(5, 12), table("pass", table("floor", true), "margin", 2)).get(0) == null, "A way was found within a box with no gap");
        square(15, 15).floor = null;
        square(15, 16).floor = null;
        found = path(area, square(15, 15), square(15, 16), table("pass", table("floor", true), "margin", 0));
        check(found.get(0) != null && (Double)found.get(1) == 1.0, "The ends were asked of the filter");
        square(15, 15).floor = floor();
        square(15, 16).floor = floor();
        for (int x = 0; x < 30; x++) square(x, 10).floor = floor();
        // The goal costs 1 whatever it is; into: a last step along a different line pays the turn again.
        found = path(area, square(0, 20), square(4, 20), table("cost", table("turn", 3), "into", table("dx", 0, "dy", 1)));
        check((Double)found.get(1) == 7.0 && steps(found.get(0)).length == 10, "into did not charge the last turn: " + found.get(1));
        found = path(area, square(0, 20), square(4, 20), table("cost", table("turn", 3), "into", table("dx", 1, "dy", 0)));
        check((Double)found.get(1) == 4.0, "into along the way was charged: " + found.get(1));
        found = path(area, square(0, 20), square(4, 20), table("cost", table("turn", 3)));
        check((Double)found.get(1) == 4.0, "A straight way was charged a turn");
        // Inside: the meta grid says so, loaded or not.
        var hall = new BuildingDef(false);
        room(grid, hall, "hall", 0, BASE + 13, BASE + 24, 3, 3);
        for (int y = 23; y <= 27; y++) for (int x = 13; x <= 15; x++) IsoWorld.instance.currentCell.squares.remove((BASE + x) + "," + (BASE + y) + ",0");
        try {
            found = path(area, square(10, 25), square(20, 25), table("cost", table("inside", 10), "margin", 0));
            check((Double)found.get(1) == 37.0, "Squares in a building, unloaded, cost " + found.get(1));
            found = path(area, square(10, 25), square(20, 25), table("cost", table("inside", 10)));
            check((Double)found.get(1) < 37.0 && (Double)found.get(1) >= 14, "The way did not go round the building: " + found.get(1));
        } finally {
            forget(grid, hall);
        }
        // A goal shut in, and a box too large.
        for (int[] d : new int[][] { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) square(25 + d[0], 25 + d[1]).floor = null;
        check(path(area, square(20, 20), square(25, 25), table("pass", table("floor", true))).get(0) == null, "A way was found into a shut square");
        rejects("options must be a table", area, "path", square(1, 1), square(2, 2), "x");
        rejects("options.margin must be a whole number from 0 to 64", area, "path", square(1, 1), square(2, 2), table("margin", 1.5));
        rejects("options.cost.turn must be a number", area, "path", square(1, 1), square(2, 2), table("cost", table("turn", -1)));
        rejects("options.into must be", area, "path", square(1, 1), square(2, 2), table("into", table("dx", 1, "dy", 1)));
        rejects("from must be a square", area, "path", "x", square(2, 2));
        rejects("to.x must be a whole number", area, "path", square(1, 1), table("x", 0.5, "y", 0, "z", 0));
        rejects("squares; at most 250000", area, "path", table("x", 0, "y", 0, "z", 0), table("x", 500, "y", 500, "z", 0));
        // The same cost as a plain Dijkstra over states, on random fields.
        for (int seed = 1; seed <= 25; seed++) random(area, new SplittableRandom(seed));
        pathCost(area);
    }

    /** A random field of walls, floors and buildings: the way's cost is the least that a plain search over (square, direction) finds. */
    private static void random(KahluaTable area, SplittableRandom dice) {
        int size = 22;
        field(size);
        var grid = IsoWorld.instance.metaGrid;
        var hall = new BuildingDef(false);
        room(grid, hall, "hall", 0, BASE + 6, BASE + 6, 5, 9);
        try {
            boolean[][] open = new boolean[size][size];
            for (int x = 0; x < size; x++) for (int y = 0; y < size; y++) {
                IsoGridSquare square = square(x, y);
                open[x][y] = dice.nextInt(6) != 0;
                if (!open[x][y]) square.floor = null;
                square.westWall = dice.nextInt(7) == 0;
                square.northWall = dice.nextInt(7) == 0;
                if (dice.nextInt(15) == 0) IsoWorld.instance.currentCell.squares.remove((BASE + x) + "," + (BASE + y) + ",0");
            }
            int fx = dice.nextInt(size), fy = dice.nextInt(size), tx = dice.nextInt(size), ty = dice.nextInt(size);
            double outside = 1 + dice.nextInt(3), inside = 1 + dice.nextInt(5), blocked = dice.nextInt(6), turn = dice.nextInt(4);
            int into = dice.nextInt(5);
            int margin = 1 + dice.nextInt(6);
            var cost = table("outside", outside, "inside", inside, "blocked", blocked, "turn", turn);
            var options = table("cost", cost, "pass", table("floor", true), "margin", margin);
            if (into > 0) options.rawset("into", table("dx", into == 1 ? 1 : into == 2 ? -1 : 0, "dy", into == 3 ? 1 : into == 4 ? -1 : 0));
            var found = FormulasTest.call(area, "path", table("x", BASE + fx, "y", BASE + fy, "z", 0), table("x", BASE + tx, "y", BASE + ty, "z", 0), options);
            double expected = reference(size, fx, fy, tx, ty, margin, outside, inside, blocked, turn, into);
            if (found.get(0) == null) { check(expected == Double.POSITIVE_INFINITY, "A way exists (" + expected + ") that was not found"); return; }
            check(expected == (Double)found.get(1), "The cost " + found.get(1) + " is not the least, " + expected);
            // The way itself: from one end to the other in steps, over squares the filter lets through, costing what it says.
            int[] flat = steps(found.get(0));
            check(flat[0] == fx && flat[1] == fy && flat[flat.length - 2] == tx && flat[flat.length - 1] == ty, "The way does not join the ends");
            double sum = 0;
            int before = 0;
            for (int at = 2; at < flat.length; at += 2) {
                int dx = flat[at] - flat[at - 2], dy = flat[at + 1] - flat[at - 1];
                check(Math.abs(dx) + Math.abs(dy) == 1, "A step is not to a square beside");
                int direction = dx > 0 ? 1 : dx < 0 ? 2 : dy > 0 ? 3 : 4;
                boolean goal = flat[at] == tx && flat[at + 1] == ty;
                sum += goal ? 1 : enters(flat[at], flat[at + 1], outside, inside, hall);
                if (before != 0 && direction != before) sum += turn;
                if (goal && into != 0 && direction != into) sum += turn;
                IsoGridSquare here = IsoWorld.instance.currentCell.getGridSquare(BASE + flat[at - 2], BASE + flat[at - 1], 0);
                IsoGridSquare there = IsoWorld.instance.currentCell.getGridSquare(BASE + flat[at], BASE + flat[at + 1], 0);
                if (here != null && there != null && here.isBlockedTo(there)) sum += blocked;
                before = direction;
            }
            check(sum == expected, "The way costs " + sum + ", not the " + expected + " it says");
        } finally {
            forget(grid, hall);
        }
    }

    private static double enters(int x, int y, double outside, double inside, BuildingDef hall) {
        return IsoWorld.instance.metaGrid.getRoomAt(BASE + x, BASE + y, 0) != null ? inside : outside;
    }

    /** A plain Dijkstra over (square, incoming direction) with the same rules, for the least cost (infinity: none). */
    private static double reference(int size, int fx, int fy, int tx, int ty, int margin, double outside, double inside, double blocked, double turn, int into) {
        int minX = Math.min(fx, tx) - margin, maxX = Math.max(fx, tx) + margin, minY = Math.min(fy, ty) - margin, maxY = Math.max(fy, ty) + margin;
        int[] dx = { 0, 1, -1, 0, 0 }, dy = { 0, 0, 0, 1, -1 };
        var best = new java.util.HashMap<Long, Double>();
        var queue = new PriorityQueue<double[]>((a, b) -> Double.compare(a[0], b[0]));
        queue.add(new double[] { 0, fx, fy, 0 });
        best.put(key(fx, fy, 0), 0.0);
        while (!queue.isEmpty()) {
            double[] top = queue.poll();
            int x = (int)top[1], y = (int)top[2], in = (int)top[3];
            if (top[0] > best.get(key(x, y, in))) continue;
            if (x == tx && y == ty) return top[0];
            for (int d = 1; d <= 4; d++) {
                int nx = x + dx[d], ny = y + dy[d];
                if (nx < minX || nx > maxX || ny < minY || ny > maxY) continue;
                IsoGridSquare there = IsoWorld.instance.currentCell.getGridSquare(BASE + nx, BASE + ny, 0);
                IsoGridSquare here = IsoWorld.instance.currentCell.getGridSquare(BASE + x, BASE + y, 0);
                double step;
                if (nx == tx && ny == ty) step = 1;
                else if (there != null && !(nx == fx && ny == fy) && there.floor == null) continue;
                else step = IsoWorld.instance.metaGrid.getRoomAt(BASE + nx, BASE + ny, 0) != null ? inside : outside;
                if (in != 0 && d != in) step += turn;
                if (nx == tx && ny == ty && into != 0 && d != into) step += turn;
                if (here != null && there != null && here.isBlockedTo(there)) step += blocked;
                double total = top[0] + step;
                Double known = best.get(key(nx, ny, d));
                if (known == null || total < known) { best.put(key(nx, ny, d), total); queue.add(new double[] { total, nx, ny, d }); }
            }
        }
        return Double.POSITIVE_INFINITY;
    }

    private static long key(int x, int y, int d) { return ((long)(x + 1000) * 5000 + y + 1000) * 8 + d; }

    /** A way over 100 x 100 squares with turns, walls and a building, and one over a wide box. */
    private static void pathCost(KahluaTable area) {
        field(100);
        var grid = IsoWorld.instance.metaGrid;
        var block = new BuildingDef(false);
        room(grid, block, "block", 0, BASE + 20, BASE + 10, 40, 80);
        try {
            for (int y = 0; y < 100; y++) for (int x = 20; x < 100; x += 20) if (y % 50 != 25) square(x, y).westWall = true;
            var options = table("cost", table("outside", 1, "inside", 4, "blocked", 30, "turn", 2), "pass", table("floor", true), "margin", 0);
            Object from = square(0, 0), to = square(99, 99);
            var found = path(area, from, to, options);
            check(found.get(0) != null, "The long way was not found");
            long best = Long.MAX_VALUE;
            for (int round = 0; round < 20; round++) {
                long start = System.nanoTime();
                path(area, from, to, options);
                best = Math.min(best, System.nanoTime() - start);
            }
            System.out.println("COST: squares.path over a 100 x 100 box (walls, a building, turns): best " + best / 1000 + " us, " + steps(found.get(0)).length / 2
                + " squares, cost " + found.get(1));
            var plain = table("cost", table("turn", 1));
            best = Long.MAX_VALUE;
            for (int round = 0; round < 20; round++) {
                long start = System.nanoTime();
                path(area, from, to, plain);
                best = Math.min(best, System.nanoTime() - start);
            }
            System.out.println("COST: squares.path over the same box in open ground (every way costs the same): best " + best / 1000 + " us");
        } finally {
            forget(grid, block);
        }
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
