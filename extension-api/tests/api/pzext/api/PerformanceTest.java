package pzext.api;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.atomic.AtomicLong;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.Lua.LuaManager;
import zombie.entity.components.fluids.FluidContainer;
import zombie.iso.BuildingDef;
import zombie.iso.IsoCell;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;
import zombie.iso.areas.isoregion.IsoRegions;
import zombie.iso.objects.IsoGenerator;
import zombie.iso.sprite.IsoSprite;
import pzext.api.Network.Position;
import pzext.boot.Hooks;

/**
 * What the performance work of the networks and the buildings must keep true: a module that fails does not stop the others; the
 * grids work out only the networks something happened to (a definition, a chunk loading, a square loaded or unloaded, a hook),
 * and nothing while nothing did; the area index answers as the areas do one by one; {@code networks.revision} moves when a
 * network's state may have; {@code buildings.version(x, y, z)} of a building moves only with what concerns it; and the
 * generators' hook allocates nothing in the steady state.
 */
final class PerformanceTest {
    private static final ClassLoader GAME = PerformanceTest.class.getClassLoader();
    private static int roomIds = 300_000;

    private PerformanceTest() { }

    static void run(KahluaTable api) throws Exception {
        KahluaCostTest.run();
        moduleFaults(api);
        areaIndex();
        idleNetworks(api);
        treesAndWater(api);
        revisions(api);
        buildingVersions(api);
        generatorUpdateCost(api);
    }

    // ---- a module that fails does not stop the others ----

    private static void moduleFaults(KahluaTable api) throws Exception {
        var world = IsoWorld.instance;
        var timers = GameApi.timers();
        var clock = timers.clock;
        var now = new AtomicLong(9_000_000_000_000L);
        timers.clock = now::get;
        var fired = new int[1];
        var area = (KahluaTable)api.rawget("timers");
        Object mod = FormulasTest.call(api, "client", "faults.mod").get(0);
        var spec = new KahluaTableImpl();
        spec.rawset("ms", 100.0);
        JavaFunction count = (frame, arguments) -> { fired[0]++; return 0; };
        double id = (Double)FormulasTest.call(area, "every", mod, spec, count).get(0);
        var saved = System.err;
        var captured = new ByteArrayOutputStream();
        System.setErr(new PrintStream(captured, true));
        try {
            GameApi.frame(GAME);
            world.brokenMetaGrid = true;
            for (int frame = 0; frame < 4; frame++) {
                now.addAndGet(150_000_000L);
                GameApi.frame(GAME);
            }
        } finally {
            world.brokenMetaGrid = false;
            System.setErr(saved);
            FormulasTest.call(area, "cancel", mod, id);
            timers.clock = clock;
        }
        String log = captured.toString();
        check(fired[0] == 4, "A module that failed stopped the timers: they were called " + fired[0] + " times of 4");
        check(count(log, "[PZExt] buildings: ") <= 1, "A failing module was reported more than once:\n" + log);
        check(log.contains("[PZExt] buildings: "), "A failing module was not reported:\n" + log);
        GameApi.frame(GAME);
        System.out.println("PASS: a module whose frame fails is reported once and leaves the others to run");
    }

    private static int count(String text, String part) {
        int found = 0;
        for (int at = text.indexOf(part); at >= 0; at = text.indexOf(part, at + 1)) found++;
        return found;
    }

    // ---- the index of many areas ----

    private static Members.Area area(int[][] squares) {
        var blocks = new HashMap<Position, Long>();
        for (int[] square : squares)
            blocks.merge(new Position(square[0] >> 3, square[1] >> 3, square[2]), 1L << ((square[1] & 7) << 3 | square[0] & 7), (a, b) -> a | b);
        return new Members.Area(new SquareMap(blocks), SquareMap.EMPTY);
    }

    private static void areaIndex() {
        var first = new Members.Area(area(new int[][] { { 10, 10, 0 }, { 11, 10, 0 }, { -3, -9, 0 } }).blocks(),
            area(new int[][] { { 12, 10, 0 } }).blocks());
        var second = area(new int[][] { { 11, 10, 0 }, { 40, 40, 1 } });
        var index = AreaIndex.of(java.util.Arrays.asList(first, null, second), false);
        check(index.any(10, 10, 0) && index.any(-3, -9, 0) && index.any(40, 40, 1) && !index.any(12, 10, 0) && !index.any(10, 10, 1),
            "The index is not the areas' squares");
        check(index.next(11, 10, 0, -1) == 0 && index.next(11, 10, 0, 0) == 2 && index.next(11, 10, 0, 2) == -1
            && index.next(10, 10, 0, 0) == -1, "The index does not list the areas that have a square in order");
        var sheltered = AreaIndex.of(java.util.Arrays.asList(first, null, second), true);
        check(sheltered.any(12, 10, 0) && sheltered.next(12, 10, 0, -1) == 0, "The shell is not in the index with shelter");
        check(AreaIndex.of(List.of(), false).isEmpty() && !AreaIndex.EMPTY.any(0, 0, 0), "The empty index has squares");
        // Against the areas one by one, many of them over each other.
        var random = new Random(7);
        var areas = new ArrayList<Members.Area>();
        var all = new ArrayList<int[][]>();
        for (int each = 0; each < 200; each++) {
            int[][] squares = new int[20][];
            for (int at = 0; at < squares.length; at++) squares[at] = new int[] { random.nextInt(64) - 20, random.nextInt(64) - 20, random.nextInt(3) };
            all.add(squares);
            areas.add(each % 17 == 0 ? null : area(squares));
        }
        var many = AreaIndex.of(areas, false);
        for (int look = 0; look < 20_000; look++) {
            int x = random.nextInt(64) - 20, y = random.nextInt(64) - 20, z = random.nextInt(3);
            int expected = -1, got = -1;
            for (int member = 0; member < areas.size() && expected < 0; member++)
                if (areas.get(member) != null && areas.get(member).contains(x, y, z)) expected = member;
            got = many.next(x, y, z, -1);
            check(expected == got, "The index and the areas differ at " + x + "," + y + "," + z + ": " + got + " against " + expected);
            int after = got;
            while (after >= 0) {
                int following = many.next(x, y, z, after), want = -1;
                for (int member = after + 1; member < areas.size() && want < 0; member++)
                    if (areas.get(member) != null && areas.get(member).contains(x, y, z)) want = member;
                check(following == want, "The index skips or repeats an area at " + x + "," + y + "," + z);
                after = following;
            }
        }
        System.out.println("PASS: the area index tells which areas have a square, in order, as the areas do one by one");
    }

    // ---- the grids work only what something happened to ----

    private static RoomDef room(List<RoomDef> made, int x, int y) {
        var room = new RoomDef(roomIds++, "kitchen", 0, new BuildingDef(false));
        room.rects.add(new RoomDef.RoomRect(x, y, 6, 6));
        IsoWorld.instance.metaGrid.rooms.add(room);
        made.add(room);
        return room;
    }

    private static void passes(Networks networks, int count) {
        for (int pass = 0; pass < count; pass++) {
            networks.pass();
            GameApi.frame(GAME);
        }
    }

    private static void idleNetworks(KahluaTable api) throws Exception {
        var networks = GameApi.networks();
        var area = (KahluaTable)api.rawget("networks");
        Object mod = FormulasTest.call(api, "client", "idle.mod").get(0);
        var rooms = new ArrayList<RoomDef>();
        int count = 30;
        for (int i = 0; i < count; i++) {
            int x = 7000 + i * 40, y = 7000;
            room(rooms, x, y);
            FormulasTest.call(area, "define", mod, "idle.p" + i, "power", "sequential");
            FormulasTest.call(area, "setProducers", mod, "idle.p" + i, list(at(x + 12, y, 0)));
            FormulasTest.call(area, "addBuilding", mod, "idle.p" + i, (double)x + 1, (double)y + 1, 0.0);
            FormulasTest.call(area, "define", mod, "idle.w" + i, "water", "fullest");
            FormulasTest.call(area, "setProducers", mod, "idle.w" + i, list(at(x + 20, y, 0)));
            FormulasTest.call(area, "addBuilding", mod, "idle.w" + i, (double)x + 1, (double)y + 1, 0.0);
        }
        try {
            passes(networks, 4);
            check(networks.active() == 0, "Networks with nothing loaded are still gone through: " + networks.active());
            long before = networks.worked();
            passes(networks, 6);
            check(networks.worked() == before, "Networks were worked out with nothing changed: " + (networks.worked() - before));

            // A definition changes: that network alone.
            FormulasTest.call(area, "setLoadFactor", mod, "idle.p3", 2.0);
            passes(networks, 1);
            check(networks.worked() == before + 1, "Changing one network worked out " + (networks.worked() - before) + " networks");
            passes(networks, 3);
            check(networks.worked() == before + 1 && networks.active() == 0, "A network changed was not settled");

            // Its producer's square loads: that network is gone through while it is loaded, and the others are not.
            IsoCell cell = IsoWorld.instance.currentCell;
            long mark = networks.worked();
            cell.load(7000 + 5 * 40 + 12, 7000, 0);
            passes(networks, 1);
            check(networks.worked() == mark + 1 && networks.active() == 1, "A loaded producer woke " + (networks.worked() - mark)
                + " networks, " + networks.active() + " active");
            passes(networks, 3);
            check(networks.worked() == mark + 4, "A loaded producer was not worked out at each pass");
            check(((KahluaTable)FormulasTest.call(area, "state", "idle.p5").get(0)).rawget("owner").equals("idle.mod"), "The state is missing");

            // Unloaded: the square goes, the chunk stays loaded (the square may come back at any time): still gone through, not worked.
            cell.squares.remove((7000 + 5 * 40 + 12) + ",7000,0");
            passes(networks, 1);
            check(networks.worked() == mark + 5, "An unloaded producer was not worked out");
            passes(networks, 3);
            check(networks.worked() == mark + 5 && networks.active() == 1, "A square missing from a loaded chunk is not looked at");
            // Back: found at once.
            cell.load(7000 + 5 * 40 + 12, 7000, 0);
            passes(networks, 1);
            check(networks.worked() == mark + 6, "A square that came back in its loaded chunk was not noticed");
            cell.squares.remove((7000 + 5 * 40 + 12) + ",7000,0");
            // The chunk goes too: now it waits for the chunk.
            cell.chunks.remove(Math.floorDiv(7000 + 5 * 40 + 12, 8) + "," + Math.floorDiv(7000, 8));
            passes(networks, 3);
            check(networks.active() == 0 && networks.worked() == mark + 7, "A network whose chunk is gone is still gone through: "
                + networks.active() + " active, " + (networks.worked() - mark) + " worked");
            cell.load(7000 + 5 * 40 + 12, 7000, 0);
            passes(networks, 1);
            check(networks.worked() == mark + 8 && networks.active() == 1, "A chunk that loaded did not wake the network that waits for it");
            cell.squares.remove((7000 + 5 * 40 + 12) + ",7000,0");
            cell.chunks.remove(Math.floorDiv(7000 + 5 * 40 + 12, 8) + "," + Math.floorDiv(7000, 8));
            passes(networks, 3);

            // The consumers' chunk loads: the network that missed it works its load out again.
            mark = networks.worked();
            cell.load(7000 + 9 * 40 + 1, 7001, 0);
            passes(networks, 2);
            check(networks.worked() - mark >= 1 && networks.worked() - mark <= 4, "A chunk of consumers woke " + (networks.worked() - mark) + " networks");
            cell.squares.remove((7000 + 9 * 40 + 1) + ",7001,0");
            cell.chunks.remove(Math.floorDiv(7000 + 9 * 40 + 1, 8) + "," + Math.floorDiv(7001, 8));
            passes(networks, 3);

            // A network removed and defined again with the same id is the new one's.
            FormulasTest.call(area, "remove", mod, "idle.p2");
            FormulasTest.call(area, "define", mod, "idle.p2", "power", "sequential");
            FormulasTest.call(area, "setProducers", mod, "idle.p2", list(at(7000 + 2 * 40 + 12, 7000, 0)));
            passes(networks, 3);
            long settled = networks.worked();
            passes(networks, 3);
            check(networks.worked() == settled && networks.active() == 0, "A network defined again does not settle");
            cell.load(7000 + 2 * 40 + 12, 7000, 0);
            passes(networks, 1);
            check(networks.worked() == settled + 1, "A network defined again is not woken by its square");
            cell.squares.remove((7000 + 2 * 40 + 12) + ",7000,0");
            cell.chunks.remove(Math.floorDiv(7000 + 2 * 40 + 12, 8) + "," + Math.floorDiv(7000, 8));
            passes(networks, 3);
            check(networks.active() == 0, "Networks stay gone through after their squares left");
        } finally {
            for (int i = 0; i < count; i++) {
                FormulasTest.call(area, "remove", mod, "idle.p" + i);
                FormulasTest.call(area, "remove", mod, "idle.w" + i);
            }
            IsoWorld.instance.metaGrid.rooms.removeAll(rooms);
            GameApi.frame(GAME);
        }
        System.out.println("PASS: the grids work out only the networks something happened to, and nothing when nothing did");
    }

    private static void treesAndWater(KahluaTable api) throws Exception {
        var networks = GameApi.networks();
        var area = (KahluaTable)api.rawget("networks");
        Object mod = FormulasTest.call(api, "client", "tree.mod").get(0);
        var rooms = new ArrayList<RoomDef>();
        room(rooms, 8000, 8000);
        room(rooms, 8040, 8000);
        var cell = IsoWorld.instance.currentCell;
        var generator = new IsoGenerator(new IsoSprite("generator"));
        generator.square = cell.load(8012, 8000, 0);
        generator.square.objects.add(generator);
        generator.setActivated(true);
        var barrel = new IsoObject(new IsoSprite("barrel"));
        barrel.fluidContainer = new FluidContainer(100, 40);
        barrel.square = cell.load(8012, 8002, 0);
        barrel.square.objects.add(barrel);
        FormulasTest.call(area, "define", mod, "tree.root", "power", "sequential");
        FormulasTest.call(area, "setProducers", mod, "tree.root", list(at(8012, 8000, 0)));
        FormulasTest.call(area, "define", mod, "tree.child", "power", "sequential");
        FormulasTest.call(area, "setParent", mod, "tree.child", "tree.root");
        FormulasTest.call(area, "addBuilding", mod, "tree.child", 8041.0, 8001.0, 0.0);
        FormulasTest.call(area, "define", mod, "tree.other", "power", "sequential");
        FormulasTest.call(area, "addBuilding", mod, "tree.other", 8001.0, 8001.0, 0.0);
        FormulasTest.call(area, "define", mod, "tree.wp", "water", "fullest");
        FormulasTest.call(area, "setProducers", mod, "tree.wp", list(at(8012, 8002, 0)));
        FormulasTest.call(area, "define", mod, "tree.wc", "water", "fullest");
        FormulasTest.call(area, "setParent", mod, "tree.wc", "tree.wp");
        FormulasTest.call(area, "addBuilding", mod, "tree.wc", 8041.0, 8001.0, 0.0);
        try {
            passes(networks, 3);
            var child = (KahluaTable)FormulasTest.call(area, "state", "tree.child").get(0);
            check(child.rawget("supplied").equals(true), "A child does not have its parent's supply: " + child.rawget("supplied"));
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.wc").get(0)).rawget("supplied").equals(true),
                "A water child does not draw from its parent's barrel");
            // The child's own load changes: the parent carries it, and only that tree is worked out.
            double rootLoad = (Double)((KahluaTable)FormulasTest.call(area, "state", "tree.root").get(0)).rawget("load");
            FormulasTest.call(area, "setExtraLoad", mod, "tree.child", 0.5);
            passes(networks, 2);
            double carried = (Double)((KahluaTable)FormulasTest.call(area, "state", "tree.root").get(0)).rawget("load");
            check(Math.abs(carried - rootLoad - 0.5) < 1e-5, "The parent does not carry its child's load: " + rootLoad + " then " + carried);
            // Switched off, the child's load is not carried.
            FormulasTest.call(area, "setEnabled", mod, "tree.child", false);
            passes(networks, 2);
            check(Math.abs((Double)((KahluaTable)FormulasTest.call(area, "state", "tree.root").get(0)).rawget("load") - rootLoad) < 1e-5,
                "A child switched off is still carried");
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.child").get(0)).rawget("supplied").equals(false),
                "A child switched off has supply");
            FormulasTest.call(area, "setEnabled", mod, "tree.child", true);
            passes(networks, 2);
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.child").get(0)).rawget("supplied").equals(true),
                "A child switched on again has no supply");
            // The parent is taken away: the child has none, and has them again when it comes back.
            FormulasTest.call(area, "remove", mod, "tree.root");
            passes(networks, 2);
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.child").get(0)).rawget("supplied").equals(false),
                "A child whose parent was removed has supply");
            FormulasTest.call(area, "define", mod, "tree.root", "power", "sequential");
            FormulasTest.call(area, "setProducers", mod, "tree.root", list(at(8012, 8000, 0)));
            passes(networks, 2);
            // (A removed parent leaves its children without one.)
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.child").get(0)).rawget("supplied").equals(false),
                "A child has the supply of a parent defined again that it was not given");
            FormulasTest.call(area, "setParent", mod, "tree.child", "tree.root");
            passes(networks, 3);
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.child").get(0)).rawget("supplied").equals(true),
                "A child does not have the supply of the parent defined again");
            // Water: the barrel runs dry, and the network that draws from it has none.
            barrel.fluidContainer.amount = 0;
            passes(networks, 2);
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.wc").get(0)).rawget("supplied").equals(false),
                "A water child draws from an empty barrel");
            barrel.fluidContainer.amount = 30;
            passes(networks, 2);
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.wc").get(0)).rawget("supplied").equals(true),
                "A water child did not get its parent's water back");
            // A producer's square moves to another network: the old owner is not asked, the new one is.
            FormulasTest.call(area, "setProducers", mod, "tree.wp", list());
            FormulasTest.call(area, "setProducers", mod, "tree.other", list(at(8012, 8002, 0)));
            passes(networks, 2);
            check(((KahluaTable)FormulasTest.call(area, "state", "tree.wc").get(0)).rawget("supplied").equals(false),
                "A water network still draws from a square that left its parent");
        } finally {
            for (String id : new String[] { "tree.child", "tree.root", "tree.other", "tree.wc", "tree.wp" })
                FormulasTest.call(area, "remove", mod, id);
            IsoWorld.instance.metaGrid.rooms.removeAll(rooms);
            generator.setActivated(false);
            cell.squares.remove("8012,8000,0");
            cell.squares.remove("8012,8002,0");
            GameApi.frame(GAME);
        }
        System.out.println("PASS: loads add up over a tree, supply follows parents, and a producer that dries up or moves is noticed by the networks that draw from it");
    }

    // ---- networks.revision ----

    private static void revisions(KahluaTable api) throws Exception {
        var networks = GameApi.networks();
        var area = (KahluaTable)api.rawget("networks");
        Object mod = FormulasTest.call(api, "client", "revision.mod").get(0);
        var rooms = new ArrayList<RoomDef>();
        room(rooms, 9000, 9000);
        FormulasTest.call(area, "define", mod, "rev.a", "power", "sequential");
        FormulasTest.call(area, "addBuilding", mod, "rev.a", 9001.0, 9001.0, 0.0);
        FormulasTest.call(area, "define", mod, "rev.b", "power", "sequential");
        FormulasTest.call(area, "setParent", mod, "rev.b", "rev.a");
        FormulasTest.call(area, "define", mod, "rev.c", "power", "sequential");
        try {
            check(FormulasTest.call(area, "revision", "rev.nothing").get(0) == null, "A network that is not has a revision");
            passes(networks, 4);
            double a = revision(area, "rev.a"), b = revision(area, "rev.b"), c = revision(area, "rev.c");
            passes(networks, 5);
            check(revision(area, "rev.a") == a && revision(area, "rev.b") == b && revision(area, "rev.c") == c,
                "A revision moved with nothing changed");
            FormulasTest.call(area, "setLoadFactor", mod, "rev.a", 3.0);
            check(revision(area, "rev.a") > a, "A revision did not move as the network was changed");
            check(revision(area, "rev.b") > b, "A child's revision did not move as its parent was changed");
            check(revision(area, "rev.c") == c, "An unrelated network's revision moved");
            double moved = revision(area, "rev.a");
            passes(networks, 3);
            double after = revision(area, "rev.a");
            check(after >= moved, "A revision went back");
            passes(networks, 3);
            check(revision(area, "rev.a") == after, "A revision moved on after the network settled");
            FormulasTest.call(area, "setExtraLoad", mod, "rev.a", 0.25);
            passes(networks, 2);
            check(revision(area, "rev.a") > after, "A revision did not move as the load did");
            // A supply starting is a change too.
            var cell = IsoWorld.instance.currentCell;
            var generator = new IsoGenerator(new IsoSprite("generator"));
            generator.square = cell.load(9012, 9000, 0);
            generator.square.objects.add(generator);
            double before = revision(area, "rev.c");
            FormulasTest.call(area, "setProducers", mod, "rev.c", list(at(9012, 9000, 0)));
            generator.setActivated(true);
            passes(networks, 3);
            check(revision(area, "rev.c") > before, "A revision did not move as a supply began");
            generator.setActivated(false);
            FormulasTest.call(area, "setProducers", mod, "rev.c", list());
            cell.squares.remove("9012,9000,0");
        } finally {
            for (String id : new String[] { "rev.b", "rev.a", "rev.c" }) FormulasTest.call(area, "remove", mod, id);
            IsoWorld.instance.metaGrid.rooms.removeAll(rooms);
            GameApi.frame(GAME);
        }
        System.out.println("PASS: networks.revision moves as a network (or one above it) changes, and stays while nothing does");
    }

    private static double revision(KahluaTable area, String id) { return (Double)FormulasTest.call(area, "revision", id).get(0); }

    // ---- buildings.version(x, y, z) ----

    private static void buildingVersions(KahluaTable api) throws Exception {
        var buildings = (KahluaTable)api.rawget("buildings");
        var rooms = new ArrayList<RoomDef>();
        var grid = IsoWorld.instance.metaGrid;
        var map = new BuildingDef(false);
        var player = new BuildingDef(true);
        var far = new BuildingDef(true);
        var mapRoom = new RoomDef(roomIds++, "kitchen", 0, map);
        mapRoom.rects.add(new RoomDef.RoomRect(10_000, 10_000, 6, 6));
        var playerRoom = new RoomDef(roomIds++, "", 0, player);
        playerRoom.rects.add(new RoomDef.RoomRect(10_100, 10_000, 4, 4));
        var farRoom = new RoomDef(roomIds++, "", 0, far);
        farRoom.rects.add(new RoomDef.RoomRect(10_400, 10_000, 4, 4));
        for (RoomDef each : new RoomDef[] { mapRoom, playerRoom, farRoom }) { grid.rooms.add(each); rooms.add(each); }
        try {
            GameApi.frame(GAME);
            var counters = (KahluaTable)FormulasTest.call(buildings, "counters").get(0);
            check(counters.rawget("swaps") != null && counters.rawget("globalBumps") != null && counters.rawget("epoch") != null,
                "buildings.counters is missing its numbers");
            check(FormulasTest.call(buildings, "version", 1.0, 1.0, 0.0).get(0) == null, "A square of no building has a version");
            double global = (Double)FormulasTest.call(buildings, "version").get(0);
            double mapVersion = version(buildings, 10_001, 10_001), playerVersion = version(buildings, 10_101, 10_001), farVersion = version(buildings, 10_401, 10_001);
            // A swap after a change in the player's building: its version moves, a building far from it does not, nor a map building's.
            Hooks.squareChanged(10_102, 10_002, 0);
            IsoRegions.swap();
            GameApi.frame(GAME);
            check(version(buildings, 10_101, 10_001) > playerVersion, "A player-built building's version did not move as its walls changed");
            check(version(buildings, 10_401, 10_001) == farVersion, "A swap after a change far away moved a building's version");
            check(version(buildings, 10_001, 10_001) == mapVersion, "A swap moved a map building's version");
            check((Double)FormulasTest.call(buildings, "version").get(0) > global, "The global version did not move with the swap");
            playerVersion = version(buildings, 10_101, 10_001);
            long bumps = counters(buildings, "globalBumps");
            // A swap whose cause the API did not see moves every player-built building's version, and is counted.
            IsoRegions.swap();
            GameApi.frame(GAME);
            check(version(buildings, 10_401, 10_001) > farVersion && version(buildings, 10_101, 10_001) > playerVersion,
                "A swap of unknown cause left a player-built building's version");
            check(version(buildings, 10_001, 10_001) == mapVersion, "A swap of unknown cause moved a map building's version");
            check(counters(buildings, "globalBumps") == bumps + 1, "A swap of unknown cause was not counted");
            // Another world: every building's.
            farVersion = version(buildings, 10_401, 10_001);
            RoomDef extra = new RoomDef(roomIds++, "", 0, new BuildingDef(false));
            extra.rects.add(new RoomDef.RoomRect(10_600, 10_000, 3, 3));
            grid.rooms.add(extra);
            rooms.add(extra);
            GameApi.buildings().changed();
            check(version(buildings, 10_001, 10_001) > mapVersion && version(buildings, 10_401, 10_001) > farVersion,
                "Describing the buildings anew left their versions");
        } finally {
            grid.rooms.removeAll(rooms);
            GameApi.buildings().changed();
            IsoRegions.swap();
            GameApi.frame(GAME);
        }
        System.out.println("PASS: buildings.version(x, y, z) moves with the building's own changes, not with the world's, and the swaps of unknown cause are counted");
    }

    private static double version(KahluaTable buildings, int x, int y) {
        Object result = FormulasTest.call(buildings, "version", (double)x, (double)y, 0.0).get(0);
        check(result != null, "No building at " + x + "," + y);
        return (Double)result;
    }

    private static long counters(KahluaTable buildings, String name) {
        return ((Double)((KahluaTable)FormulasTest.call(buildings, "counters").get(0)).rawget(name)).longValue();
    }

    // ---- the generators' hook allocates nothing ----

    private static void generatorUpdateCost(KahluaTable api) throws Exception {
        var area = (KahluaTable)api.rawget("networks");
        var cell = IsoWorld.instance.currentCell;
        Object mod = FormulasTest.call(api, "client", "update.mod").get(0);
        var rooms = new ArrayList<RoomDef>();
        room(rooms, 11_000, 11_000);
        var generator = new IsoGenerator(new IsoSprite("generator"));
        generator.square = cell.load(11_012, 11_000, 0);
        generator.square.objects.add(generator);
        generator.setActivated(true);
        FormulasTest.call(area, "define", mod, "update.p", "power", "sequential");
        FormulasTest.call(area, "setProducers", mod, "update.p", list(at(11_012, 11_000, 0)));
        FormulasTest.call(area, "addBuilding", mod, "update.p", 11_001.0, 11_001.0, 0.0);
        try {
            passes(GameApi.networks(), 3);
            for (int warm = 0; warm < 50_000; warm++) Hooks.generatorUpdate(generator);
            long bytes = Allocations.median(9, () -> { for (int call = 0; call < 20_000; call++) Hooks.generatorUpdate(generator); });
            check(bytes < 2048, "20,000 generator updates allocated " + bytes + " bytes");
            long start = System.nanoTime();
            for (int call = 0; call < 200_000; call++) Hooks.generatorUpdate(generator);
            System.out.printf("generator update: %.0f ns a call in a network, %d bytes over 20,000 calls%n",
                (System.nanoTime() - start) / 200_000.0, bytes);
        } finally {
            FormulasTest.call(area, "remove", mod, "update.p");
            generator.setActivated(false);
            cell.squares.remove("11012,11000,0");
            IsoWorld.instance.metaGrid.rooms.removeAll(rooms);
            GameApi.frame(GAME);
        }
        System.out.println("PASS: a generator's update in a network allocates nothing in the steady state");
    }

    private static KahluaTable at(int x, int y, int z) {
        KahluaTable result = LuaManager.platform.newTable();
        result.rawset("x", (double)x); result.rawset("y", (double)y); result.rawset("z", (double)z);
        return result;
    }

    private static KahluaTable list(Object... items) {
        KahluaTable result = LuaManager.platform.newTable();
        for (int index = 0; index < items.length; index++) result.rawset((double)(index + 1), items[index]);
        return result;
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
