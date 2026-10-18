package pzext.api;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.SplittableRandom;
import java.util.stream.Stream;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.ZomboidFileSystem;
import zombie.iso.BuildingDef;
import zombie.iso.IsoCell;
import zombie.iso.IsoLot;
import zombie.iso.IsoMetaGrid;
import zombie.iso.IsoWorld;
import zombie.iso.MapFiles;
import zombie.iso.RoomDef;
import zombie.iso.zones.Zone;

/**
 * {@code zones.clusters} (docs/design.md, "Map facts") against the synthetic game: the joining by gap, the area and boxes, the
 * buildings in a cluster, what is kept for a world and on disk for a map set (a second game with the same map files does not read the
 * zones; a changed file, a cut-short or old file, a folder that cannot be written), the options, and what it costs.
 */
final class ZoneClustersTest {
    private static final ClassLoader GAME = ZoneClustersTest.class.getClassLoader();
    private static long roomIds = 9_000_000;

    private ZoneClustersTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        IsoMetaGrid grid = IsoWorld.instance.metaGrid;
        var zones = new ArrayList<>(grid.zones);
        String cache = ZomboidFileSystem.cacheFolder;
        var maps = new ArrayList<>(IsoLot.MapFiles);
        Path work = Files.createTempDirectory("pzext-clusters");
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            grid.zones.clear();
            IsoLot.MapFiles.clear();
            ZomboidFileSystem.cacheFolder = null;
            var area = (KahluaTable)api.rawget("zones");
            check(area.rawget("clusters") != null, "zones.clusters is missing");
            joined(area, grid);
            buildings(area, grid, (KahluaTable)api.rawget("buildings"));
            mistakes(area);
            disk(area, grid, work);
            cost(area, grid, work);
        } finally {
            IsoWorld.instance.metaGrid = grid;
            grid.zones.clear();
            grid.zones.addAll(zones);
            IsoLot.MapFiles.clear();
            IsoLot.MapFiles.addAll(maps);
            ZomboidFileSystem.cacheFolder = cache;
            IsoWorld.instance.setCell(home);
            GameApi.frame(GAME);
            try (Stream<Path> walk = Files.walk(work)) { walk.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete()); }
        }
    }

    // ---- helpers ----

    private static KahluaTable table(Object... pairs) {
        var result = new KahluaTableImpl();
        for (int at = 0; at < pairs.length; at += 2) result.rawset(pairs[at], pairs[at + 1] instanceof Integer n ? (Object)(double)n : pairs[at + 1]);
        return result;
    }

    private static List<Object> items(Object table) {
        var kahlua = (KahluaTable)table;
        var result = new ArrayList<Object>();
        for (int at = 1; at <= kahlua.len(); at++) result.add(kahlua.rawget((double)at));
        return result;
    }

    private static double number(Object table, String key) { return (Double)((KahluaTable)table).rawget(key); }

    private static List<Object> clusters(KahluaTable area, String type, KahluaTable options) {
        return items(options == null ? FormulasTest.call(area, "clusters", type).get(0) : FormulasTest.call(area, "clusters", type, options).get(0));
    }

    private static void rejects(String message, KahluaTable area, Object... arguments) {
        try {
            FormulasTest.call(area, "clusters", arguments);
            throw new AssertionError("clusters took " + java.util.Arrays.toString(arguments));
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message) && expected.getMessage().contains("PZExtAPI.zones.clusters"), expected.getMessage());
        }
    }

    private static void zone(IsoMetaGrid grid, String type, int x, int y, int w, int h) { grid.zones.add(new Zone("", type, x, y, 0, w, h)); }

    private static List<Double> rects(Object cluster) {
        var result = new ArrayList<Double>();
        for (Object value : items(((KahluaTable)cluster).rawget("rects"))) result.add((Double)value);
        return result;
    }

    // ---- joining ----

    private static void joined(KahluaTable area, IsoMetaGrid grid) {
        check(clusters(area, "TownZone", null).isEmpty(), "A map with no zones has clusters");
        // A and B touch; C is 5 squares from B; D and E overlap; the others are of other types.
        zone(grid, "TownZone", 1000, 1000, 10, 10);
        zone(grid, "TownZone", 1010, 1000, 10, 10);
        zone(grid, "TownZone", 1025, 1000, 10, 10);
        zone(grid, "TownZone", 3000, 3000, 20, 20);
        zone(grid, "TownZone", 3010, 3010, 20, 20);
        zone(grid, "Forest", 1005, 1005, 100, 100);
        zone(grid, "Nav", 1030, 1000, 50, 50);
        var plain = clusters(area, "TownZone", null);
        check(plain.size() == 3, "Three clusters expected, got " + plain.size());
        var overlap = plain.get(0);
        check(number(overlap, "area") == 700 && number(overlap, "zones") == 2 && number(overlap, "x1") == 3000 && number(overlap, "y1") == 3000
            && number(overlap, "x2") == 3029 && number(overlap, "y2") == 3029, "The overlapping zones' cluster is wrong");
        var touching = plain.get(1);
        check(number(touching, "area") == 200 && number(touching, "zones") == 2 && number(touching, "x1") == 1000 && number(touching, "x2") == 1019
            && number(touching, "y2") == 1009, "The touching zones' cluster is wrong");
        check(rects(touching).equals(List.of(1000.0, 1000.0, 10.0, 10.0, 1010.0, 1000.0, 10.0, 10.0)), "The boxes are wrong: " + rects(touching));
        check(number(plain.get(2), "area") == 100 && number(plain.get(2), "zones") == 1, "The single zone's cluster is wrong");
        check(((KahluaTable)touching).rawget("buildings") == null, "Buildings were given without being asked for");
        // The gap: 5 squares between B and C joins them at 5, not at 4.
        check(clusters(area, "TownZone", table("gap", 4)).size() == 3, "A gap of 4 joined zones 5 apart");
        var gapped = clusters(area, "TownZone", table("gap", 5));
        check(gapped.size() == 2 && number(gapped.get(0), "area") == 700 && number(gapped.get(1), "area") == 300 && number(gapped.get(1), "zones") == 3,
            "A gap of 5 did not join zones 5 apart");
        check(clusters(area, "TownZone", table("gap", 999)).size() == 2, "A wide gap joined the far clusters");
        check(clusters(area, "TownZone", table("minArea", 150)).size() == 2 && clusters(area, "TownZone", table("minArea", 701)).isEmpty(),
            "minArea is wrong");
        check(clusters(area, "Forest", null).size() == 1 && clusters(area, "Swamp", null).isEmpty(), "A type is not told from the others");
        // The gap is a distance between the boxes: 3 squares each way is 4.2 apart.
        zone(grid, "Diagonal", 500, 500, 10, 10);
        zone(grid, "Diagonal", 513, 513, 10, 10);
        check(clusters(area, "Diagonal", table("gap", 4)).size() == 2 && clusters(area, "Diagonal", table("gap", 5)).size() == 1,
            "A diagonal gap is not a distance");
        // A zone with no size is one square.
        zone(grid, "Point", 700, 700, 0, 0);
        var point = clusters(area, "Point", null);
        check(point.size() == 1 && number(point.get(0), "area") == 1, "A point zone is not a square");
        // Against a plain O(n^2) join with the area counted square by square.
        var random = new SplittableRandom(7);
        for (int at = 0; at < 150; at++) zone(grid, "Random", 5000 + random.nextInt(400), 5000 + random.nextInt(400), 1 + random.nextInt(30), 1 + random.nextInt(30));
        for (int gap : new int[] { 0, 3, 17 }) {
            var expected = plainJoin(grid, "Random", gap);
            var found = new ArrayList<>(clusters(area, "Random", table("gap", gap)));
            found.sort((x, y) -> number(x, "area") != number(y, "area") ? Double.compare(number(y, "area"), number(x, "area"))
                : Double.compare(number(y, "zones"), number(x, "zones")));
            check(found.size() == expected.size(), "gap " + gap + ": " + found.size() + " clusters, expected " + expected.size());
            for (int at = 0; at < found.size(); at++) {
                check(number(found.get(at), "area") == expected.get(at)[0] && number(found.get(at), "zones") == expected.get(at)[1],
                    "gap " + gap + ": cluster " + at + " is " + number(found.get(at), "area") + "/" + number(found.get(at), "zones")
                    + ", expected " + expected.get(at)[0] + "/" + expected.get(at)[1]);
            }
        }
    }

    /** The clusters by a plain join of every pair, with the area counted square by square: area and zones, the largest area first. */
    private static List<long[]> plainJoin(IsoMetaGrid grid, String type, int gap) {
        var boxes = new ArrayList<Zone>();
        for (Zone zone : grid.zones) if (zone.type.equals(type)) boxes.add(zone);
        int n = boxes.size();
        int[] parent = new int[n];
        for (int at = 0; at < n; at++) parent[at] = at;
        for (int a = 0; a < n; a++) {
            for (int b = a + 1; b < n; b++) {
                Zone p = boxes.get(a), q = boxes.get(b);
                long dx = Math.max(0, Math.max(q.x - (p.x + Math.max(1, p.w)), p.x - (q.x + Math.max(1, q.w))));
                long dy = Math.max(0, Math.max(q.y - (p.y + Math.max(1, p.h)), p.y - (q.y + Math.max(1, q.h))));
                if (dx * dx + dy * dy <= (long)gap * gap) {
                    int ra = root(parent, a), rb = root(parent, b);
                    if (ra != rb) parent[ra] = rb;
                }
            }
        }
        var squares = new java.util.HashMap<Integer, Set<Long>>();
        var counts = new java.util.HashMap<Integer, Integer>();
        for (int at = 0; at < n; at++) {
            int r = root(parent, at);
            counts.merge(r, 1, Integer::sum);
            Set<Long> covered = squares.computeIfAbsent(r, k -> new HashSet<>());
            Zone zone = boxes.get(at);
            for (int x = zone.x; x < zone.x + Math.max(1, zone.w); x++) for (int y = zone.y; y < zone.y + Math.max(1, zone.h); y++) covered.add((long)x << 32 | y);
        }
        var result = new ArrayList<long[]>();
        for (int r : squares.keySet()) result.add(new long[] { squares.get(r).size(), counts.get(r) });
        result.sort((a, b) -> a[0] != b[0] ? Long.compare(b[0], a[0]) : Long.compare(b[1], a[1]));
        return result;
    }

    private static int root(int[] parent, int at) {
        while (parent[at] != at) at = parent[at];
        return at;
    }

    // ---- buildings ----

    private static BuildingDef building(IsoMetaGrid grid, boolean built, int x, int y, int w, int h) {
        var def = new BuildingDef(built);
        var room = new RoomDef(roomIds++, "room", 0, def);
        room.rects.add(new RoomDef.RoomRect(x, y, w, h));
        grid.rooms.add(room);
        grid.buildings.add(def);
        return def;
    }

    private static void buildings(KahluaTable area, IsoMetaGrid grid, KahluaTable buildings) {
        grid.zones.clear();
        zone(grid, "TownZone", 20000, 20000, 100, 100);
        zone(grid, "TownZone", 20100, 20000, 100, 100);
        zone(grid, "TownZone", 20400, 20000, 50, 50);
        var inside = building(grid, false, 20010, 20010, 10, 10);
        var second = building(grid, false, 20150, 20050, 8, 8);
        var between = building(grid, false, 20250, 20010, 10, 10);
        var built = building(grid, true, 20020, 20030, 6, 6);
        var apart = building(grid, false, 20410, 20010, 10, 10);
        var empty = new BuildingDef(false);
        grid.buildings.add(empty);
        GameApi.buildings().changed();
        try {
            var found = clusters(area, "TownZone", table("buildings", true));
            check(found.size() == 2, "Two clusters expected: " + found.size());
            var big = (KahluaTable)found.get(0);
            Set<Object> keys = new HashSet<>(items(big.rawget("buildings")));
            check(keys.equals(Set.of("20010,20010,0", "20150,20050,0")), "The cluster's buildings are wrong: " + keys);
            check(items(((KahluaTable)found.get(1)).rawget("buildings")).equals(List.of("20410,20010,0")), "The far cluster's buildings are wrong");
            Object at = FormulasTest.call(buildings, "at", 20010.0, 20010.0, 0.0).get(0);
            check(keys.contains(((KahluaTable)at).rawget("key")), "A key is not buildings.at's");
            check(((KahluaTable)clusters(area, "TownZone", table("buildings", false)).get(0)).rawget("buildings") == null, "buildings = false gave buildings");
            // A building made later is in the cluster once the game's buildings change; a gap joins the clusters and the one between.
            var later = building(grid, false, 20060, 20060, 10, 10);
            GameApi.buildings().changed();
            Set<Object> after = new HashSet<>(items(((KahluaTable)clusters(area, "TownZone", table("buildings", true)).get(0)).rawget("buildings")));
            check(after.contains("20060,20060,0"), "A building made later was not in the cluster: " + after);
            grid.buildings.remove(later);
            grid.rooms.removeAll(later.rooms);
            GameApi.buildings().changed();
            var wide = clusters(area, "TownZone", table("buildings", true, "gap", 200));
            check(wide.size() == 1 && items(((KahluaTable)wide.get(0)).rawget("buildings")).size() == 3, "A gap that joins the clusters kept the buildings apart");
        } finally {
            for (BuildingDef def : new BuildingDef[] { inside, second, between, built, apart, empty }) {
                grid.buildings.remove(def);
                grid.rooms.removeAll(def.rooms);
            }
            GameApi.buildings().changed();
            grid.zones.clear();
        }
    }

    // ---- mistakes ----

    private static void mistakes(KahluaTable area) {
        rejects("type must be a string", area);
        rejects("type must be a string", area, 4.0);
        rejects("options must be a table", area, "TownZone", "x");
        rejects("options.gap must be a whole number", area, "TownZone", table("gap", 1.5));
        rejects("options.gap must be a whole number", area, "TownZone", table("gap", -1));
        rejects("options.gap must be a whole number", area, "TownZone", table("gap", 100000));
        rejects("options.minArea must be a number", area, "TownZone", table("minArea", "x"));
        rejects("options.buildings must be true or false", area, "TownZone", table("buildings", 1));
        rejects("options.gapp is not an option", area, "TownZone", table("gapp", 1));
    }

    // ---- the disk ----

    private static List<Path> files(Path cache) throws IOException {
        Path folder = cache.resolve("pzext").resolve("maps");
        if (!Files.isDirectory(folder)) return List.of();
        try (Stream<Path> list = Files.list(folder)) { return list.sorted().toList(); }
    }

    private static IsoMetaGrid secondGame(IsoMetaGrid like) {
        var next = new IsoMetaGrid();
        next.zones.addAll(like.zones);
        IsoWorld.instance.metaGrid = next;
        return next;
    }

    private static void disk(KahluaTable area, IsoMetaGrid grid, Path work) throws Exception {
        Path cache = work.resolve("cache"), maps = work.resolve("maps"), map = maps.resolve("Muldraugh, KY");
        Files.createDirectories(map);
        Files.writeString(map.resolve("objects.lua"), "objects = {}");
        Files.writeString(map.resolve("1_1.lotheader"), "h");
        ZomboidFileSystem.cacheFolder = cache.toString();
        IsoLot.MapFiles.clear();
        IsoLot.MapFiles.add(new MapFiles("Muldraugh, KY", map.toString()));
        grid.zones.clear();
        var random = new SplittableRandom(3);
        for (int at = 0; at < 300; at++) zone(grid, "TownZone", 8000 + random.nextInt(3000), 8000 + random.nextInt(3000), 5 + random.nextInt(60), 5 + random.nextInt(60));
        zone(grid, "Forest", 8000, 8000, 3000, 3000);
        var options = table("gap", 10);
        // The first game works it out and keeps it.
        Zone.reads = 0;
        var first = clusters(area, "TownZone", options);
        check(Zone.reads == 300, "The zones were read " + Zone.reads + " times by the first game");
        check(files(cache).size() == 1, "The answer was not kept on disk: " + files(cache));
        long kept = Zone.reads;
        clusters(area, "TownZone", options);
        check(Zone.reads == kept, "A second call read the zones again");
        // Another type and another option set are other questions, with files of their own.
        clusters(area, "Forest", options);
        clusters(area, "TownZone", table("gap", 11));
        check(files(cache).size() == 3, "Each question has a file: " + files(cache));
        // A second game, the same map files: the answer is read from the disk, the zones not walked.
        secondGame(grid);
        Zone.reads = 0;
        var again = clusters(area, "TownZone", options);
        check(Zone.reads == 0, "A second game read the zones (" + Zone.reads + ") instead of the disk");
        check(same(first, again), "The answer from the disk differs from the one worked out");
        check(files(cache).size() == 3, "Reading the disk wrote files");
        // The map files changed: it is worked out again, and the file is written again.
        Files.writeString(map.resolve("objects.lua"), "objects = { more = true }");
        secondGame(grid);
        Zone.reads = 0;
        check(same(first, clusters(area, "TownZone", options)), "The answer after a changed file differs");
        check(Zone.reads == 300, "A changed objects.lua was not worked out again: " + Zone.reads);
        secondGame(grid);
        Zone.reads = 0;
        clusters(area, "TownZone", options);
        check(Zone.reads == 0 && files(cache).size() == 3, "The answer of the changed files was not kept");
        // More zones (a mod registered some): not the answer that was kept.
        IsoMetaGrid second = secondGame(grid);
        zone(second, "TownZone", 14000, 14000, 10, 10);
        Zone.reads = 0;
        check(clusters(area, "TownZone", options).size() == first.size() + 1 && Zone.reads == 301, "A map with another number of zones used the kept answer");
        // Another list of maps: another file.
        IsoLot.MapFiles.add(new MapFiles("Mod Map", maps.resolve("Mod Map").toString()));
        Files.createDirectories(maps.resolve("Mod Map"));
        secondGame(grid);
        Zone.reads = 0;
        clusters(area, "TownZone", options);
        check(Zone.reads == 300 && files(cache).size() == 4, "Another list of maps used the kept answer: " + Zone.reads + " " + files(cache).size());
        IsoLot.MapFiles.remove(1);
        // A broken file, a cut-short file, an old file and one with a flipped byte are ignored and written again.
        Path own = work.resolve("own-cache");
        ZomboidFileSystem.cacheFolder = own.toString();
        secondGame(grid);
        clusters(area, "TownZone", options);
        Path made = files(own).get(0);
        byte[] bytes = Files.readAllBytes(made);
        for (int kind = 0; kind < 4; kind++) {
            byte[] bad = switch (kind) {
                case 0 -> java.util.Arrays.copyOf(bytes, bytes.length / 2);
                case 1 -> { byte[] copy = bytes.clone(); copy[4] = 2; yield copy; }
                case 2 -> { byte[] copy = bytes.clone(); copy[copy.length - 1] ^= 0x55; yield copy; }
                default -> new byte[] { 1, 2, 3 };
            };
            Files.write(made, bad);
            secondGame(grid);
            Zone.reads = 0;
            check(same(first, clusters(area, "TownZone", options)), "A broken file (" + kind + ") gave a different answer");
            check(Zone.reads == 300, "A broken file (" + kind + ") was read: " + Zone.reads);
            check(java.util.Arrays.equals(Files.readAllBytes(made), bytes), "A broken file (" + kind + ") was not written again");
        }
        check(files(own).size() == 1, "A broken file left others: " + files(own));
        check(files(own).stream().noneMatch(path -> path.getFileName().toString().endsWith(".tmp")), "A temporary file stayed");
        // A cache folder that cannot be written (a file where the folder should be): the answer is worked out and the game goes on.
        Path blocked = work.resolve("blocked");
        Files.writeString(blocked, "a file");
        ZomboidFileSystem.cacheFolder = blocked.toString();
        secondGame(grid);
        Zone.reads = 0;
        check(same(first, clusters(area, "TownZone", options)) && Zone.reads == 300, "A cache folder that cannot be written changed the answer");
        ZomboidFileSystem.cacheFolder = null;
        secondGame(grid);
        check(same(first, clusters(area, "TownZone", options)), "No cache folder changed the answer");
        IsoLot.MapFiles.clear();
        secondGame(grid);
        Zone.reads = 0;
        check(same(first, clusters(area, "TownZone", options)) && Zone.reads == 300, "No maps listed changed the answer");
        IsoWorld.instance.metaGrid = grid;
    }

    private static boolean same(List<Object> a, List<Object> b) {
        if (a.size() != b.size()) return false;
        for (int at = 0; at < a.size(); at++) {
            for (String key : new String[] { "x1", "y1", "x2", "y2", "area", "zones" }) if (number(a.get(at), key) != number(b.get(at), key)) return false;
            if (!rects(a.get(at)).equals(rects(b.get(at)))) return false;
        }
        return true;
    }

    // ---- cost ----

    /** Several thousand zones, as a map has: the first call joins them, a call after it only looks. */
    private static void cost(KahluaTable area, IsoMetaGrid grid, Path work) throws Exception {
        Path cache = work.resolve("cost-cache"), map = work.resolve("cost-maps");
        Files.createDirectories(map);
        Files.writeString(map.resolve("objects.lua"), "objects = {}");
        ZomboidFileSystem.cacheFolder = cache.toString();
        IsoLot.MapFiles.clear();
        IsoLot.MapFiles.add(new MapFiles("Cost", map.toString()));
        grid.zones.clear();
        var random = new SplittableRandom(11);
        for (int at = 0; at < 12_000; at++) zone(grid, at % 3 == 0 ? "Forest" : "TownZone", 6000 + random.nextInt(9000), 6000 + random.nextInt(9000), 4 + random.nextInt(90), 4 + random.nextInt(90));
        for (int at = 0; at < 8_000; at++) zone(grid, "Vegitation", 6000 + random.nextInt(9000), 6000 + random.nextInt(9000), 20 + random.nextInt(200), 20 + random.nextInt(200));
        var options = table("gap", 6);
        long start = System.nanoTime();
        FormulasTest.call(area, "clusters", "TownZone", options);
        long firstTime = System.nanoTime() - start;
        var first = clusters(area, "TownZone", options);
        long best = Long.MAX_VALUE;
        for (int at = 0; at < 20; at++) {
            start = System.nanoTime();
            FormulasTest.call(area, "clusters", "TownZone", options);
            best = Math.min(best, System.nanoTime() - start);
        }
        secondGame(grid);
        start = System.nanoTime();
        FormulasTest.call(area, "clusters", "TownZone", options);
        long diskTime = System.nanoTime() - start;
        var fromDisk = clusters(area, "TownZone", options);
        check(same(first, fromDisk), "The answer from the disk differs at scale");
        System.out.println("COST: zones.clusters over " + grid.zones.size() + " zones (8000 of the type): first call (joins them, writes the disk) " + firstTime / 1_000_000.0
            + " ms; a second game (reads the disk) " + diskTime / 1_000_000.0 + " ms; cached call " + best / 1000 + " us; " + first.size() + " clusters");
        IsoWorld.instance.metaGrid = grid;
        long without = System.nanoTime();
        IsoLot.MapFiles.clear();
        secondGame(grid);
        FormulasTest.call(area, "clusters", "TownZone", options);
        System.out.println("COST: zones.clusters with no map list (joins every game): " + (System.nanoTime() - without) / 1_000_000.0 + " ms");
        IsoWorld.instance.metaGrid = grid;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
