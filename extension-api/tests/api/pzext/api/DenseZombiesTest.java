package pzext.api;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.SplittableRandom;
import java.util.stream.Stream;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaTableImpl;
import zombie.ZomboidFileSystem;
import zombie.iso.IsoCell;
import zombie.iso.IsoLot;
import zombie.iso.IsoMetaCell;
import zombie.iso.IsoMetaGrid;
import zombie.iso.IsoWorld;
import zombie.iso.LotHeader;
import zombie.iso.MapFiles;

/**
 * {@code zombies.dense} (docs/design.md, "Map facts") against the synthetic game: the groups of chunks (8 neighbours, across cells), their
 * middle, reach, peak, mean, order and rank, checked against a plain flood fill; a chunk the game has made is asked, one it has not is
 * not made; what is kept for a world and on disk for a map set; the options; and what it costs on a 40 by 40 cell map.
 */
final class DenseZombiesTest {
    private static final ClassLoader GAME = DenseZombiesTest.class.getClassLoader();

    private DenseZombiesTest() { }

    static void run(KahluaTable api) throws Exception {
        IsoCell home = IsoWorld.instance.currentCell;
        IsoMetaGrid grid = IsoWorld.instance.metaGrid;
        String cache = ZomboidFileSystem.cacheFolder;
        var maps = new ArrayList<>(IsoLot.MapFiles);
        Path work = Files.createTempDirectory("pzext-dense");
        try {
            IsoWorld.instance.setCell(new IsoCell());
            GameApi.frame(GAME);
            IsoLot.MapFiles.clear();
            ZomboidFileSystem.cacheFolder = null;
            var zombies = (KahluaTable)api.rawget("zombies");
            check(zombies.rawget("dense") != null && zombies.rawget("near") != null, "zombies.dense is missing or took zombies.near away");
            groups(zombies);
            wide(zombies);
            mistakes(zombies);
            disk(zombies, work);
            cost(zombies, work);
        } finally {
            IsoWorld.instance.metaGrid = grid;
            IsoLot.MapFiles.clear();
            IsoLot.MapFiles.addAll(maps);
            ZomboidFileSystem.cacheFolder = cache;
            IsoWorld.instance.setCell(home);
            GameApi.frame(GAME);
            try (Stream<Path> walk = Files.walk(work)) { walk.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete()); }
        }
    }

    /**
     * B42's grid: the cells a map may use run from -250 to 250 on a side (501 by 501, too many chunks for one raster), whatever the map
     * has. Only the cells with a map's data are read: one cell here, at (10, 12), two dense chunks side by side in it.
     */
    private static void wide(KahluaTable zombies) {
        var cells = new IsoMetaCell[501][501];
        cells[260][262] = new IsoMetaCell(10, 12);
        var grid = new IsoMetaGrid();
        grid.setCells(-250, -250, cells);
        IsoWorld.instance.metaGrid = grid;
        set(grid, 260 - 280, 262 - 275, 3, 4, 200);
        set(grid, 260 - 280, 262 - 275, 4, 4, 180);
        List<Object> found = dense(zombies, "min", 100);
        check(found.size() == 1 && number(found.get(0), "chunks") == 2 && number(found.get(0), "peak") == 200,
            "A map on B42's wide grid is not read by its cells: " + found);
    }

    // ---- helpers ----

    private static KahluaTable table(Object... pairs) {
        var result = new KahluaTableImpl();
        for (int at = 0; at < pairs.length; at += 2) result.rawset(pairs[at], pairs[at + 1] instanceof Integer n ? (Object)(double)n : pairs[at + 1]);
        return result;
    }

    private static List<Object> dense(KahluaTable zombies, Object... pairs) {
        var found = new ArrayList<Object>();
        var list = (KahluaTable)FormulasTest.call(zombies, "dense", table(pairs)).get(0);
        for (int at = 1; at <= list.len(); at++) found.add(list.rawget((double)at));
        return found;
    }

    private static double number(Object table, String key) { return (Double)((KahluaTable)table).rawget(key); }

    private static void rejects(String message, KahluaTable zombies, Object... arguments) {
        try {
            FormulasTest.call(zombies, "dense", arguments);
            throw new AssertionError("dense took " + java.util.Arrays.toString(arguments));
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains(message) && expected.getMessage().contains("PZExtAPI.zombies.dense"), expected.getMessage());
        }
    }

    /** A map of cells starting at cell (30, 25); a cell is null where the map has none. */
    private static IsoMetaGrid map(int width, int height) {
        var cells = new IsoMetaCell[width][height];
        for (int x = 0; x < width; x++) for (int y = 0; y < height; y++) cells[x][y] = new IsoMetaCell(30 + x, 25 + y);
        var grid = new IsoMetaGrid();
        grid.setCells(30, 25, cells);
        IsoWorld.instance.metaGrid = grid;
        return grid;
    }

    private static IsoMetaCell cell(IsoMetaGrid grid, int x, int y) { return grid.getCellData(30 + x, 25 + y); }

    private static void set(IsoMetaGrid grid, int cellX, int cellY, int x, int y, int value) {
        cell(grid, cellX, cellY).info.setZombieIntensity(y * 32 + x, (byte)value);
    }

    // ---- the oracle: a flood fill over a map of the chunks, written for the spec ----

    private record Expected(double x, double y, double r, int x1, int y1, int x2, int y2, int chunks, int peak, double mean) { }

    private static List<Expected> oracle(IsoMetaGrid grid, int min, int minChunks) {
        var at = new HashMap<Long, Integer>();
        for (int cx = 0; cx < grid.gridX(); cx++) {
            for (int cy = 0; cy < grid.gridY(); cy++) {
                IsoMetaCell cell = grid.getCellData(30 + cx, 25 + cy);
                if (cell == null || cell.info == null) continue;
                for (int x = 0; x < 32; x++) {
                    for (int y = 0; y < 32; y++) {
                        int value = cell.hasChunk(x, y) ? cell.getChunk(x, y).getUnadjustedZombieIntensity() : Math.max(0, LotHeader.getZombieIntensityForChunk(cell.info, x, y));
                        if (value >= min) at.put(((long)(30 + cx) * 32 + x) << 32 | ((25 + cy) * 32 + y), value);
                    }
                }
            }
        }
        var seen = new java.util.HashSet<Long>();
        var result = new ArrayList<Expected>();
        for (long start : new ArrayList<>(at.keySet())) {
            if (!seen.add(start)) continue;
            var members = new ArrayList<Long>();
            var queue = new ArrayDeque<Long>();
            queue.add(start);
            while (!queue.isEmpty()) {
                long chunk = queue.poll();
                members.add(chunk);
                long gx = chunk >> 32, gy = (int)chunk;
                for (int dx = -1; dx <= 1; dx++) {
                    for (int dy = -1; dy <= 1; dy++) {
                        long next = (gx + dx) << 32 | (gy + dy) & 0xFFFFFFFFL;
                        if (at.containsKey(next) && seen.add(next)) queue.add(next);
                    }
                }
            }
            if (members.size() < minChunks) continue;
            double sx = 0, sy = 0, sum = 0;
            int peak = 0;
            long lowX = Long.MAX_VALUE, lowY = Long.MAX_VALUE, highX = Long.MIN_VALUE, highY = Long.MIN_VALUE;
            for (long chunk : members) {
                long gx = chunk >> 32, gy = (int)chunk;
                sx += gx * 8 + 4;
                sy += gy * 8 + 4;
                int value = at.get(chunk);
                sum += value;
                peak = Math.max(peak, value);
                lowX = Math.min(lowX, gx);
                highX = Math.max(highX, gx);
                lowY = Math.min(lowY, gy);
                highY = Math.max(highY, gy);
            }
            double x = sx / members.size(), y = sy / members.size(), r = 0;
            for (long chunk : members) {
                long gx = chunk >> 32, gy = (int)chunk;
                // The farthest of the chunk's four corners.
                for (int corner = 0; corner < 4; corner++) {
                    double px = gx * 8 + (corner % 2 == 0 ? 0 : 8), py = gy * 8 + (corner < 2 ? 0 : 8);
                    r = Math.max(r, Math.hypot(px - x, py - y));
                }
            }
            result.add(new Expected(x, y, r, (int)lowX * 8, (int)lowY * 8, (int)highX * 8 + 7, (int)highY * 8 + 7, members.size(), peak, sum / members.size()));
        }
        result.sort(Comparator.comparingDouble(Expected::mean).reversed().thenComparing(Comparator.comparingInt(Expected::chunks).reversed())
            .thenComparingInt(Expected::y1).thenComparingInt(Expected::x1));
        return result;
    }

    private static void matches(List<Object> found, List<Expected> expected, String what) {
        check(found.size() == expected.size(), what + ": " + found.size() + " groups, expected " + expected.size());
        for (int at = 0; at < found.size(); at++) {
            Object group = found.get(at);
            Expected want = expected.get(at);
            String message = what + ": group " + (at + 1) + " is wrong: ";
            check(Math.abs(number(group, "x") - want.x()) < 1e-6 && Math.abs(number(group, "y") - want.y()) < 1e-6, message + "middle " + number(group, "x") + "," + number(group, "y") + " expected " + want);
            check(Math.abs(number(group, "r") - want.r()) < 1e-6, message + "r " + number(group, "r") + " expected " + want.r());
            check(number(group, "x1") == want.x1() && number(group, "y1") == want.y1() && number(group, "x2") == want.x2() && number(group, "y2") == want.y2(), message + "box");
            check(number(group, "chunks") == want.chunks() && number(group, "peak") == want.peak() && Math.abs(number(group, "mean") - want.mean()) < 1e-9, message + "chunks, peak or mean");
            check(number(group, "rank") == at + 1, message + "rank");
        }
    }

    // ---- the groups ----

    private static void groups(KahluaTable zombies) {
        IsoMetaGrid grid = map(4, 3);
        check(dense(zombies, "min", 100).isEmpty(), "A map with no intensity has groups");
        // A: six chunks in a block, one a peak, and one joined only at a corner. Below the minimum: a chunk near it.
        for (int x = 5; x <= 7; x++) for (int y = 5; y <= 6; y++) set(grid, 0, 0, x, y, 200);
        set(grid, 0, 0, 6, 5, 250);
        set(grid, 0, 0, 8, 7, 180);
        set(grid, 0, 0, 10, 10, 100);
        // B: two chunks at the east edge of a cell and two at the west edge of the next.
        for (int y = 3; y <= 4; y++) { set(grid, 0, 0, 31, y, 150); set(grid, 1, 0, 0, y, 150); }
        // C: one chunk with the largest value there is, alone in a far cell.
        set(grid, 2, 2, 16, 16, 255);
        // D: a chunk the game made, then changed to a high value; and one the header makes high that the game made low.
        set(grid, 1, 2, 3, 3, 10);
        cell(grid, 1, 2).getChunk(3, 3).setZombieIntensity((byte)220);
        set(grid, 2, 1, 20, 20, 240);
        cell(grid, 2, 1).getChunk(20, 20).setZombieIntensity((byte)5);
        // A cell with no map data at all in the middle, and one whose header is missing.
        cell(grid, 3, 1).info = null;
        var found = dense(zombies, "min", 128);
        matches(found, oracle(grid, 128, 1), "min 128");
        check(found.size() == 4, "Four groups expected: " + found.size());
        // B by hand: chunks 991, 992 by 803, 804.
        Object b = null;
        for (Object group : found) if (number(group, "chunks") == 4) b = group;
        check(b != null && number(b, "x") == 7936 && number(b, "y") == 6432 && Math.abs(number(b, "r") - Math.sqrt(128)) < 1e-9 && number(b, "x1") == 7928
            && number(b, "x2") == 7943 && number(b, "y1") == 6424 && number(b, "y2") == 6439 && number(b, "peak") == 150 && number(b, "mean") == 150,
            "The group across two cells is wrong");
        // The order: the densest (by mean) first, then more chunks.
        for (int at = 1; at < found.size(); at++)
            check(number(found.get(at - 1), "mean") >= number(found.get(at), "mean"), "The groups are not in order of density");
        check(number(found.get(0), "mean") == 255 && number(found.get(0), "chunks") == 1, "The densest group is not first");
        // Options.
        matches(dense(zombies, "min", 128, "minChunks", 4), oracle(grid, 128, 4), "minChunks 4");
        check(dense(zombies, "min", 128, "minChunks", 4).size() == 2, "minChunks left single chunks");
        matches(dense(zombies, "min", 1), oracle(grid, 1, 1), "min 1");
        matches(dense(zombies, "min", 255), oracle(grid, 255, 1), "min 255");
        // A chunk the game has not made is not made by the walk.
        check(!cell(grid, 0, 0).hasChunk(5, 5), "The walk made a chunk");
        // Kept for the world: a second call asks no chunk.
        IsoMetaCell.reads = 0;
        dense(zombies, "min", 128);
        check(IsoMetaCell.reads == 0, "A second call walked the map again");
        // A random field against the oracle.
        var random = new SplittableRandom(5);
        IsoMetaGrid field = map(3, 3);
        for (int cx = 0; cx < 3; cx++) for (int cy = 0; cy < 3; cy++) for (int at = 0; at < 90; at++)
            set(field, cx, cy, random.nextInt(32), random.nextInt(32), 100 + random.nextInt(156));
        for (int[] each : new int[][] { { 1, 1 }, { 150, 1 }, { 180, 3 }, { 200, 1 }, { 230, 2 } })
            matches(dense(zombies, "min", each[0], "minChunks", each[1]), oracle(field, each[0], each[1]), "random " + each[0] + "/" + each[1]);
        // A new world is another map.
        IsoMetaGrid other = map(1, 1);
        check(dense(zombies, "min", 128).isEmpty(), "A new world answered with the last one's groups");
        IsoWorld.instance.metaGrid = other;
    }

    // ---- mistakes ----

    private static void mistakes(KahluaTable zombies) {
        rejects("options must be a table", zombies);
        rejects("options must be a table", zombies, "x");
        rejects("options.min must be a whole number", zombies, table());
        rejects("options.min must be a whole number", zombies, table("min", 0));
        rejects("options.min must be a whole number", zombies, table("min", 256));
        rejects("options.min must be a whole number", zombies, table("min", 1.5));
        rejects("options.min must be a whole number", zombies, table("min", "x"));
        rejects("options.minChunks must be a whole number", zombies, table("min", 10, "minChunks", 0));
        rejects("options.minChunks must be a whole number", zombies, table("min", 10, "minChunks", "x"));
        rejects("options.peak is not an option", zombies, table("min", 10, "peak", 1));
    }

    // ---- the disk ----

    private static List<Path> files(Path cache) throws IOException {
        Path folder = cache.resolve("pzext").resolve("maps");
        if (!Files.isDirectory(folder)) return List.of();
        try (Stream<Path> list = Files.list(folder)) { return list.sorted().toList(); }
    }

    /** A second game: a new meta grid over the same cells. */
    private static IsoMetaGrid secondGame(IsoMetaGrid like, IsoMetaCell[][] cells) {
        var next = new IsoMetaGrid();
        next.setCells(like.getMinX(), like.getMinY(), cells);
        IsoWorld.instance.metaGrid = next;
        return next;
    }

    private static IsoMetaCell[][] cellsOf(IsoMetaGrid grid) {
        var cells = new IsoMetaCell[grid.gridX()][grid.gridY()];
        for (int x = 0; x < cells.length; x++) for (int y = 0; y < cells[x].length; y++) cells[x][y] = grid.getCellData(30 + x, 25 + y);
        return cells;
    }

    private static boolean same(List<Object> a, List<Object> b) {
        if (a.size() != b.size()) return false;
        for (int at = 0; at < a.size(); at++)
            for (String key : new String[] { "x", "y", "r", "x1", "y1", "x2", "y2", "chunks", "peak", "mean", "rank" })
                if (number(a.get(at), key) != number(b.get(at), key)) return false;
        return true;
    }

    private static void disk(KahluaTable zombies, Path work) throws Exception {
        Path cache = work.resolve("cache"), map = work.resolve("maps").resolve("Muldraugh, KY");
        Files.createDirectories(map);
        Files.writeString(map.resolve("0_0.lotheader"), "header");
        Files.writeString(map.resolve("objects.lua"), "objects = {}");
        ZomboidFileSystem.cacheFolder = cache.toString();
        IsoLot.MapFiles.clear();
        IsoLot.MapFiles.add(new MapFiles("Muldraugh, KY", map.toString()));
        IsoMetaGrid grid = map(5, 4);
        var random = new SplittableRandom(9);
        for (int cx = 0; cx < 5; cx++) for (int cy = 0; cy < 4; cy++) for (int at = 0; at < 120; at++)
            set(grid, cx, cy, random.nextInt(32), random.nextInt(32), 60 + random.nextInt(196));
        IsoMetaCell[][] cells = cellsOf(grid);
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        var first = dense(zombies, "min", 140, "minChunks", 2);
        check(IsoMetaCell.reads > 0 && !first.isEmpty(), "The first game did not walk the map");
        check(files(cache).size() == 1, "The answer was not kept on disk: " + files(cache));
        dense(zombies, "min", 170);
        check(files(cache).size() == 2, "Each question has a file: " + files(cache));
        // A second game over the same map files reads the disk and walks nothing.
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        var again = dense(zombies, "min", 140, "minChunks", 2);
        check(IsoMetaCell.reads == 0, "A second game walked the map (" + IsoMetaCell.reads + ") instead of reading the disk");
        check(same(first, again), "The answer from the disk differs from the one worked out");
        check(files(cache).size() == 2, "Reading the disk wrote files");
        // Other lot header files (one more): worked out again, kept again.
        Files.writeString(map.resolve("0_1.lotheader"), "header");
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        check(same(first, dense(zombies, "min", 140, "minChunks", 2)) && IsoMetaCell.reads > 0, "A new lot header did not make it work the answer out again");
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        dense(zombies, "min", 140, "minChunks", 2);
        check(IsoMetaCell.reads == 0 && files(cache).size() == 2, "The answer of the changed files was not kept");
        // A header that grew.
        Files.writeString(map.resolve("0_1.lotheader"), "a longer header");
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        dense(zombies, "min", 140, "minChunks", 2);
        check(IsoMetaCell.reads > 0, "A changed lot header did not make it work the answer out again");
        // objects.lua is not what the zombie intensity comes from.
        Files.writeString(map.resolve("objects.lua"), "objects = { more }");
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        dense(zombies, "min", 140, "minChunks", 2);
        check(IsoMetaCell.reads == 0, "A changed objects.lua made it walk the map");
        // A map of another size is another map.
        IsoMetaGrid bigger = new IsoMetaGrid();
        var wider = new IsoMetaCell[6][4];
        for (int x = 0; x < 6; x++) for (int y = 0; y < 4; y++) wider[x][y] = x < 5 ? cells[x][y] : new IsoMetaCell(30 + x, 25 + y);
        bigger.setCells(30, 25, wider);
        IsoWorld.instance.metaGrid = bigger;
        IsoMetaCell.reads = 0;
        dense(zombies, "min", 140, "minChunks", 2);
        check(IsoMetaCell.reads > 0, "A map of another size used the kept answer");
        // Broken files are ignored and written again.
        Path own = work.resolve("own-cache");
        ZomboidFileSystem.cacheFolder = own.toString();
        secondGame(grid, cells);
        dense(zombies, "min", 140, "minChunks", 2);
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
            secondGame(grid, cells);
            IsoMetaCell.reads = 0;
            check(same(first, dense(zombies, "min", 140, "minChunks", 2)), "A broken file (" + kind + ") gave a different answer");
            check(IsoMetaCell.reads > 0, "A broken file (" + kind + ") was read");
            check(java.util.Arrays.equals(Files.readAllBytes(made), bytes), "A broken file (" + kind + ") was not written again");
        }
        check(files(own).size() == 1, "Broken files left others: " + files(own));
        // A folder that cannot be written, none, and no map list: worked out, nothing fails.
        Path blocked = work.resolve("blocked");
        Files.writeString(blocked, "a file");
        ZomboidFileSystem.cacheFolder = blocked.toString();
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        check(same(first, dense(zombies, "min", 140, "minChunks", 2)) && IsoMetaCell.reads > 0, "A cache folder that cannot be written changed the answer");
        ZomboidFileSystem.cacheFolder = null;
        secondGame(grid, cells);
        check(same(first, dense(zombies, "min", 140, "minChunks", 2)), "No cache folder changed the answer");
        ZomboidFileSystem.cacheFolder = cache.toString();
        IsoLot.MapFiles.clear();
        secondGame(grid, cells);
        IsoMetaCell.reads = 0;
        check(same(first, dense(zombies, "min", 140, "minChunks", 2)) && IsoMetaCell.reads > 0, "No maps listed changed the answer");
    }

    // ---- cost ----

    /** A map of 40 by 40 cells (1,638,400 chunks) with blobs of dense chunks: the first call walks it, a call after it only looks. */
    private static void cost(KahluaTable zombies, Path work) throws Exception {
        Path cache = work.resolve("cost-cache"), map = work.resolve("cost-maps");
        Files.createDirectories(map);
        Files.writeString(map.resolve("0_0.lotheader"), "header");
        ZomboidFileSystem.cacheFolder = cache.toString();
        IsoLot.MapFiles.clear();
        IsoLot.MapFiles.add(new MapFiles("Cost", map.toString()));
        IsoMetaGrid grid = map(40, 40);
        var random = new SplittableRandom(13);
        for (int blob = 0; blob < 4000; blob++) {
            int gx = random.nextInt(40 * 32), gy = random.nextInt(40 * 32), radius = 1 + random.nextInt(4), value = 80 + random.nextInt(176);
            for (int x = gx - radius; x <= gx + radius; x++) {
                for (int y = gy - radius; y <= gy + radius; y++) {
                    if (x < 0 || y < 0 || x >= 40 * 32 || y >= 40 * 32 || (x - gx) * (x - gx) + (y - gy) * (y - gy) > radius * radius) continue;
                    set(grid, x / 32, y / 32, x % 32, y % 32, value);
                }
            }
        }
        IsoMetaCell[][] cells = cellsOf(grid);
        long start = System.nanoTime();
        FormulasTest.call(zombies, "dense", table("min", 128, "minChunks", 3));
        long firstTime = System.nanoTime() - start;
        var first = dense(zombies, "min", 128, "minChunks", 3);
        long best = Long.MAX_VALUE;
        for (int at = 0; at < 20; at++) {
            start = System.nanoTime();
            FormulasTest.call(zombies, "dense", table("min", 128, "minChunks", 3));
            best = Math.min(best, System.nanoTime() - start);
        }
        secondGame(grid, cells);
        start = System.nanoTime();
        FormulasTest.call(zombies, "dense", table("min", 128, "minChunks", 3));
        long diskTime = System.nanoTime() - start;
        var fromDisk = dense(zombies, "min", 128, "minChunks", 3);
        check(same(first, fromDisk), "The answer from the disk differs at scale");
        IsoLot.MapFiles.clear();
        secondGame(grid, cells);
        start = System.nanoTime();
        FormulasTest.call(zombies, "dense", table("min", 128, "minChunks", 3));
        long without = System.nanoTime() - start;
        System.out.println("COST: zombies.dense over 40 x 40 cells (1,638,400 chunks), " + first.size() + " groups: first call (walks the map, writes the disk) "
            + firstTime / 1_000_000.0 + " ms; a second game (reads the disk) " + diskTime / 1_000_000.0 + " ms; cached call " + best / 1000
            + " us; walk again with no map list " + without / 1_000_000.0 + " ms");
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

}
