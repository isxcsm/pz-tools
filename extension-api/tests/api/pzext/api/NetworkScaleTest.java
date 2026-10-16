package pzext.api;

import java.util.ArrayList;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.iso.IsoWorld;
import zombie.iso.RoomDef;
import zombie.iso.BuildingDef;

/**
 * The networks at the scale a mod may build them to (Building Utilities' tier rework, 2e): a thousand buildings of one room
 * over the map, none loaded, each with a power network and a water network of its own and a producer each. Times the
 * frames that work the networks out (once a second, and the five-second look at loads not complete) at the game's pace,
 * a frame every 16 ms for seven seconds, after three seconds that let the networks settle as they do in a running game.
 * Printed for the report against the goal (half a millisecond a second), not held to it: a loaded machine's noise would fail it;
 * the networks are removed after.
 */
final class NetworkScaleTest {
    private static final ClassLoader GAME = NetworkScaleTest.class.getClassLoader();
    private static final int BUILDINGS = 1000;

    private NetworkScaleTest() { }

    static void run(KahluaTable api) throws Exception {
        // What the performance work keeps true (see PerformanceTest), then the networks at scale.
        PerformanceTest.run(api);
        var grid = IsoWorld.instance.metaGrid;
        var made = new ArrayList<RoomDef>();
        for (int i = 0; i < BUILDINGS; i++) {
            int x = 1000 + (i % 40) * 30, y = 1000 + (i / 40) * 30;
            var room = new RoomDef(100_000 + i, "kitchen", 0, new BuildingDef(false));
            room.rects.add(new RoomDef.RoomRect(x, y, 10, 10));
            grid.rooms.add(room);
            made.add(room);
        }
        var networks = (KahluaTable)api.rawget("networks");
        Object mod = FormulasTest.call(api, "client", "scale.mod").get(0);
        for (int i = 0; i < BUILDINGS; i++) {
            int x = 1000 + (i % 40) * 30, y = 1000 + (i / 40) * 30;
            FormulasTest.call(networks, "define", mod, "power" + i, "power", "sequential");
            FormulasTest.call(networks, "setProducers", mod, "power" + i, list(at(x + 12, y, 0)));
            FormulasTest.call(networks, "addBuilding", mod, "power" + i, (double)x + 1, (double)y + 1, 0.0);
            FormulasTest.call(networks, "define", mod, "water" + i, "water", "fullest");
            FormulasTest.call(networks, "setProducers", mod, "water" + i, list(at(x + 2, y + 2, 0)));
            FormulasTest.call(networks, "addBuilding", mod, "water" + i, (double)x + 1, (double)y + 1, 0.0);
        }
        try {
            // The first frames define and look at everything, and a second pass settles what the first left unsettled (a
            // network's history begun, a snapshot made); three seconds at the game's pace, then the measure.
            for (int frame = 0; frame < 3; frame++) GameApi.frame(GAME);
            for (long end = System.nanoTime() + 3_000_000_000L; System.nanoTime() < end;) {
                GameApi.frame(GAME);
                Thread.sleep(16);
            }
            var work = new ArrayList<Double>();
            long end = System.nanoTime() + 7_000_000_000L;
            while (System.nanoTime() < end) {
                long start = System.nanoTime();
                GameApi.frame(GAME);
                double ms = (System.nanoTime() - start) / 1e6;
                if (ms > 0.05) work.add(ms);
                Thread.sleep(16);
            }
            work.sort(null);
            double total = 0;
            for (double ms : work) total += ms;
            System.out.printf("networks at scale (%d buildings, power and water each, none loaded): %d frames worked them out,"
                + " median %.2f ms, most %.2f ms, %.2f ms a second (goal 0.5)%n", BUILDINGS, work.size(),
                work.isEmpty() ? 0 : work.get(work.size() / 2), work.isEmpty() ? 0 : work.get(work.size() - 1), total / 7);
        } finally {
            for (int i = 0; i < BUILDINGS; i++) {
                FormulasTest.call(networks, "remove", mod, "power" + i);
                FormulasTest.call(networks, "remove", mod, "water" + i);
            }
            grid.rooms.removeAll(made);
            GameApi.frame(GAME);
        }
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
}
