package pzext.api;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import pzext.api.Buildings.Building;

/**
 * {@code PZExtAPI.zones.clusters}: the map's zones of one type joined where they touch or lie near each other, each cluster with its
 * box, area, rectangles and, when asked, the map buildings in it (docs/design.md, "Map facts"). A mod that looks for towns or woods
 * cannot walk the map's thousands of zones in Lua each time it asks; here the zones are read once a world and option set, joined
 * with a union-find over a grid of buckets (each zone meets only the zones that share a bucket with it, not all of them), and the answer
 * is kept for the world and, on disk, for the map set ({@link MapCache}).
 *
 * <p>A zone is its box ({@code x, y, w, h}; a polygon or a line by the box that holds it), at least one square wide and high. Two
 * zones join when the gap between their boxes, as the distance between the nearest squares of the two, is at most {@code gap}; boxes
 * that overlap or touch have gap 0. A cluster's {@code area} is the squares its boxes cover together (an overlap counts once), its
 * {@code x2} and {@code y2} the last square. The clusters come largest area first.
 *
 * <p>The buildings are the map's, those with a room that has a square (as {@code buildings.list} has them) and not what players
 * built; a building is in a cluster when its middle, as {@code buildings.list} gives it, lies in one of the cluster's boxes. They are
 * worked out from the clusters for the buildings' epoch ({@link Buildings#epoch()}), not kept on disk: rooms change as a game goes.
 */
final class ZoneClusters {
    /** The widest gap a call takes, and the most zones one world may hold: bounds on the work of one call, not rules of play. */
    static final int MAX_GAP = 1000, MAX_ZONES = (1 << 21) - 1;
    private static final String AREA = "PZExtAPI.zones.clusters";
    private static final double LIMIT = 1e12;
    /** The squares on a side of a bucket the zones are met in. */
    private static final int BUCKET = 128;
    /** What a bucket's coordinates are offset by to be positive, in 21 bits each. */
    private static final int OFFSET = 1 << 20;
    /** The most answers kept for a world. */
    private static final int KEPT = 16;

    private final Kahlua lua;
    private final Game game;
    private final Buildings buildings;
    private final MapCache disk;
    // IsoMetaGrid.getZones(), getBuildings(); Zone.getType(), getX(), getY(), getWidth(), getHeight().
    private final MethodHandle zones, all, type, atX, atY, width, height;

    /** One cluster: its box, area, zone count and boxes (x, y, w, h each). */
    private record Cluster(int x1, int y1, int x2, int y2, long area, int zones, int[] rects) { }

    /** A question's answer, with the building keys of each cluster once asked for (for the epoch they were read at). */
    private static final class Answer {
        final Cluster[] clusters;
        Lookup lookup;
        String[][] keys;
        long epoch = -1;

        // The number of zones the map had when it was made: zones registered since make it stale.
        final int zones;

        Answer(Cluster[] clusters, int zones) { this.clusters = clusters; this.zones = zones; }
    }

    /** What is asked: the type, the gap, the smallest area, and whether the buildings are wanted. */
    private record Wanted(String type, int gap, long minArea, boolean buildings) {
        String key() { return type + '\0' + gap + '\0' + minArea; }
    }

    // The answers for the meta grid they were made for; another world or grid takes them away.
    private final LinkedHashMap<String, Answer> kept = new LinkedHashMap<>();
    private Object grid;

    ZoneClusters(Kahlua lua, Game game, Buildings buildings, MapCache disk, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.buildings = buildings;
        this.disk = disk;
        Class<?> meta = Game.type(loader, "zombie.iso.IsoMetaGrid"), zone = Game.type(loader, "zombie.iso.zones.Zone");
        zones = Game.exact(meta.getMethod("getZones"), MethodType.methodType(List.class, Object.class));
        all = Game.exact(meta.getMethod("getBuildings"), MethodType.methodType(List.class, Object.class));
        type = Game.exact(zone.getMethod("getType"), MethodType.methodType(String.class, Object.class));
        MethodType number = MethodType.methodType(int.class, Object.class);
        atX = Game.exact(zone.getMethod("getX"), number);
        atY = Game.exact(zone.getMethod("getY"), number);
        width = Game.exact(zone.getMethod("getWidth"), number);
        height = Game.exact(zone.getMethod("getHeight"), number);
    }

    /** Sets the function into the zones' table. */
    void register(Object table) throws ReflectiveOperationException {
        lua.set(table, "clusters", lua.function(AREA, arguments -> new Object[] { clusters(arguments) }));
    }

    private synchronized Object clusters(Object[] arguments) throws ReflectiveOperationException {
        Wanted wanted = wanted(arguments);
        Object meta = game.metaGrid();
        if (meta == null) return lua.table();
        if (meta != grid) {
            kept.clear();
            grid = meta;
        }
        try {
            List<?> list = (List<?>)zones.invokeExact(meta);
            int count = list == null ? 0 : list.size();
            Answer answer = kept.get(wanted.key());
            if (answer == null || answer.zones != count) {
                answer = new Answer(read(meta, wanted, list, count), count);
                if (kept.size() >= KEPT) kept.remove(kept.keySet().iterator().next());
                kept.put(wanted.key(), answer);
            }
            if (wanted.buildings()) keys(meta, answer);
            return list(answer, wanted.buildings());
        } catch (ReflectiveOperationException | RuntimeException caller) {
            throw caller;
        } catch (Throwable failure) { throw Game.thrown(failure); }
    }

    // ---- the options ----

    private Wanted wanted(Object[] arguments) throws ReflectiveOperationException {
        String type = Arguments.string(arguments, 0, AREA, "type");
        Object options = arguments.length > 1 ? arguments[1] : null;
        int gap = 0;
        long minArea = 0;
        boolean buildings = false;
        if (options != null) {
            if (!lua.isTable(options)) throw new IllegalArgumentException(AREA + ": options must be a table");
            for (var entry : lua.entries(options)) {
                Object name = entry.getKey(), value = entry.getValue();
                if ("gap".equals(name)) {
                    if (!(value instanceof Double number) || number != Math.rint(number) || number < 0 || number > MAX_GAP)
                        throw new IllegalArgumentException(AREA + ": options.gap must be a whole number from 0 to " + MAX_GAP);
                    gap = number.intValue();
                } else if ("minArea".equals(name)) {
                    if (!(value instanceof Double number) || !(number >= 0 && number <= LIMIT))
                        throw new IllegalArgumentException(AREA + ": options.minArea must be a number from 0 to " + LIMIT);
                    minArea = (long)Math.ceil(number);
                } else if ("buildings".equals(name)) {
                    if (!(value instanceof Boolean flag)) throw new IllegalArgumentException(AREA + ": options.buildings must be true or false");
                    buildings = flag;
                } else {
                    throw new IllegalArgumentException(AREA + ": options." + name + " is not an option (gap, minArea, buildings)");
                }
            }
        }
        return new Wanted(type, gap, minArea, buildings);
    }

    // ---- reading: the disk, or the grid ----

    /** The clusters of the question: from the disk when the map set was seen, else from the zones, and then kept on the disk. */
    private Cluster[] read(Object meta, Wanted wanted, List<?> list, int count) throws Throwable {
        if (count > MAX_ZONES) throw new IllegalArgumentException(AREA + ": the map has " + count + " zones; at most " + MAX_ZONES);
        String question = null, stamp = null;
        if (disk != null) {
            MapCache.Maps maps = disk.maps(true);
            if (maps != null) {
                // The zones the map has plus those mods registered: their number is part of what the answer was made for.
                question = "zones\n" + wanted.key() + '\n' + maps.names();
                stamp = maps.stamp() + "zones " + count + '\n';
                byte[] saved = disk.read(question, stamp);
                if (saved != null) {
                    Cluster[] found = decode(saved);
                    if (found != null) return found;
                }
            }
        }
        Cluster[] made = join(list, count, wanted);
        if (question != null) disk.write(question, stamp, encode(made));
        return made;
    }

    // ---- joining ----

    private Cluster[] join(List<?> list, int count, Wanted wanted) throws Throwable {
        int[] xs = new int[count], ys = new int[count], ws = new int[count], hs = new int[count];
        int zonesOfType = 0;
        for (int index = 0; index < count; index++) {
            Object zone = list.get(index);
            if (zone == null || !wanted.type().equals((String)type.invokeExact(zone))) continue;
            xs[zonesOfType] = (int)atX.invokeExact(zone);
            ys[zonesOfType] = (int)atY.invokeExact(zone);
            ws[zonesOfType] = Math.max(1, (int)width.invokeExact(zone));
            hs[zonesOfType] = Math.max(1, (int)height.invokeExact(zone));
            zonesOfType++;
        }
        if (zonesOfType == 0) return new Cluster[0];
        int n = zonesOfType, gap = wanted.gap();
        int[] parent = new int[n];
        for (int index = 0; index < n; index++) parent[index] = index;

        // Each zone is met in the buckets its box, grown by half the gap and one square, touches: two zones within the gap share one.
        int grow = gap / 2 + 1;
        long[] entries = buckets(xs, ys, ws, hs, n, grow);
        for (int from = 0, size = entries.length; from < size; ) {
            int to = from + 1;
            long bucket = entries[from] >>> 21;
            while (to < size && entries[to] >>> 21 == bucket) to++;
            for (int a = from; a < to; a++) {
                int first = (int)(entries[a] & (1 << 21) - 1);
                for (int b = a + 1; b < to; b++) {
                    int second = (int)(entries[b] & (1 << 21) - 1);
                    if (first == second) continue;
                    int rootA = find(parent, first), rootB = find(parent, second);
                    if (rootA != rootB && near(xs, ys, ws, hs, first, second, gap)) parent[rootA] = rootB;
                }
            }
            from = to;
        }

        // The zones by their cluster, in the order of the zones.
        int[] root = new int[n];
        for (int index = 0; index < n; index++) root[index] = find(parent, index);
        long[] ordered = new long[n];
        for (int index = 0; index < n; index++) ordered[index] = (long)root[index] << 21 | index;
        Arrays.sort(ordered);
        var found = new ArrayList<Cluster>();
        for (int from = 0; from < n; ) {
            int to = from + 1;
            while (to < n && ordered[to] >>> 21 == ordered[from] >>> 21) to++;
            int size = to - from;
            int[] members = new int[size], rects = new int[size * 4];
            int x1 = Integer.MAX_VALUE, y1 = Integer.MAX_VALUE, x2 = Integer.MIN_VALUE, y2 = Integer.MIN_VALUE;
            for (int at = 0; at < size; at++) {
                int zone = (int)(ordered[from + at] & (1 << 21) - 1);
                members[at] = zone;
                rects[at * 4] = xs[zone];
                rects[at * 4 + 1] = ys[zone];
                rects[at * 4 + 2] = ws[zone];
                rects[at * 4 + 3] = hs[zone];
                x1 = Math.min(x1, xs[zone]);
                y1 = Math.min(y1, ys[zone]);
                x2 = Math.max(x2, xs[zone] + ws[zone] - 1);
                y2 = Math.max(y2, ys[zone] + hs[zone] - 1);
            }
            long area = covered(rects, size);
            if (area >= wanted.minArea()) found.add(new Cluster(x1, y1, x2, y2, area, size, rects));
            from = to;
        }
        found.sort(Comparator.comparingLong(Cluster::area).reversed().thenComparingInt(Cluster::y1).thenComparingInt(Cluster::x1));
        return found.toArray(new Cluster[0]);
    }

    private static int find(int[] parent, int index) {
        while (parent[index] != index) {
            parent[index] = parent[parent[index]];
            index = parent[index];
        }
        return index;
    }

    /** Whether the nearest squares of the two boxes are at most the gap apart (boxes that overlap or touch: gap 0). */
    private static boolean near(int[] xs, int[] ys, int[] ws, int[] hs, int a, int b, int gap) {
        long dx = Math.max(0, Math.max(xs[b] - (xs[a] + ws[a]), xs[a] - (xs[b] + ws[b])));
        long dy = Math.max(0, Math.max(ys[b] - (ys[a] + hs[a]), ys[a] - (ys[b] + hs[b])));
        return dx * dx + dy * dy <= (long)gap * gap;
    }

    private static long bucketKey(int bucketX, int bucketY) { return (long)(bucketX + OFFSET) << 21 | (bucketY + OFFSET); }

    /** The pairs (bucket, box number) of the boxes grown by {@code grow} squares, sorted, so that a bucket's boxes are a run. */
    private static long[] buckets(int[] xs, int[] ys, int[] ws, int[] hs, int n, int grow) {
        int size = 0;
        for (int index = 0; index < n; index++) {
            size += (Math.floorDiv(xs[index] + ws[index] - 1 + grow, BUCKET) - Math.floorDiv(xs[index] - grow, BUCKET) + 1)
                * (Math.floorDiv(ys[index] + hs[index] - 1 + grow, BUCKET) - Math.floorDiv(ys[index] - grow, BUCKET) + 1);
        }
        long[] entries = new long[size];
        int at = 0;
        for (int index = 0; index < n; index++) {
            for (int bx = Math.floorDiv(xs[index] - grow, BUCKET), lastX = Math.floorDiv(xs[index] + ws[index] - 1 + grow, BUCKET); bx <= lastX; bx++)
                for (int by = Math.floorDiv(ys[index] - grow, BUCKET), lastY = Math.floorDiv(ys[index] + hs[index] - 1 + grow, BUCKET); by <= lastY; by++)
                    entries[at++] = bucketKey(bx, by) << 21 | index;
        }
        Arrays.sort(entries);
        return entries;
    }

    // ---- the area a cluster covers ----

    /** The squares the boxes ({@code x, y, w, h} each) cover together: a sweep over x with a segment tree over the y that are covered. */
    private static long covered(int[] rects, int count) {
        if (count == 1) return (long)rects[2] * rects[3];
        int[] ys = new int[count * 2];
        for (int at = 0; at < count; at++) {
            ys[at * 2] = rects[at * 4 + 1];
            ys[at * 2 + 1] = rects[at * 4 + 1] + rects[at * 4 + 3];
        }
        Arrays.sort(ys);
        int levels = 0;
        for (int at = 0; at < ys.length; at++) if (at == 0 || ys[at] != ys[at - 1]) ys[levels++] = ys[at];
        int[] cover = new int[levels * 4];
        long[] length = new long[levels * 4];
        long[] events = new long[count * 2];
        for (int at = 0; at < count; at++) {
            events[at * 2] = ((long)rects[at * 4] + OFFSET) << 32 | (long)at * 2;
            events[at * 2 + 1] = ((long)rects[at * 4] + rects[at * 4 + 2] + OFFSET) << 32 | (long)at * 2 + 1;
        }
        Arrays.sort(events);
        long area = 0;
        long previous = events[0] >>> 32;
        for (long event : events) {
            long x = event >>> 32;
            area += length[1] * (x - previous);
            previous = x;
            int code = (int)event, rect = code >> 1;
            int low = Arrays.binarySearch(ys, 0, levels, rects[rect * 4 + 1]);
            int high = Arrays.binarySearch(ys, 0, levels, rects[rect * 4 + 1] + rects[rect * 4 + 3]);
            update(cover, length, ys, 1, 0, levels - 2, low, high - 1, (code & 1) == 0 ? 1 : -1);
        }
        return area;
    }

    /** Adds {@code delta} to the cover of the elementary intervals {@code from..to} (interval i is ys[i] to ys[i + 1]). */
    private static void update(int[] cover, long[] length, int[] ys, int node, int left, int right, int from, int to, int delta) {
        if (from > right || to < left || left > right) return;
        if (from <= left && right <= to) {
            cover[node] += delta;
        } else {
            int middle = (left + right) / 2;
            update(cover, length, ys, node * 2, left, middle, from, to, delta);
            update(cover, length, ys, node * 2 + 1, middle + 1, right, from, to, delta);
        }
        // The node covers intervals left..right; interval i is ys[i] to ys[i + 1].
        if (cover[node] > 0) length[node] = (long)ys[right + 1] - ys[left];
        else length[node] = left == right ? 0 : length[node * 2] + length[node * 2 + 1];
    }

    // ---- the disk ----

    private static byte[] encode(Cluster[] clusters) throws IOException {
        var bytes = new ByteArrayOutputStream();
        try (var out = new DataOutputStream(bytes)) {
            out.writeInt(clusters.length);
            for (Cluster cluster : clusters) {
                out.writeInt(cluster.x1());
                out.writeInt(cluster.y1());
                out.writeInt(cluster.x2());
                out.writeInt(cluster.y2());
                out.writeLong(cluster.area());
                out.writeInt(cluster.zones());
                for (int value : cluster.rects()) out.writeInt(value);
            }
        }
        return bytes.toByteArray();
    }

    /** The clusters of a file, or null for one that is not what was written. */
    private static Cluster[] decode(byte[] data) {
        try (var in = new DataInputStream(new ByteArrayInputStream(data))) {
            int count = in.readInt();
            if (count < 0 || count > data.length) return null;
            Cluster[] clusters = new Cluster[count];
            for (int at = 0; at < count; at++) {
                int x1 = in.readInt(), y1 = in.readInt(), x2 = in.readInt(), y2 = in.readInt();
                long area = in.readLong();
                int zones = in.readInt();
                if (zones < 1 || zones > data.length / 16) return null;
                int[] rects = new int[zones * 4];
                for (int value = 0; value < rects.length; value++) rects[value] = in.readInt();
                clusters[at] = new Cluster(x1, y1, x2, y2, area, zones, rects);
            }
            return in.read() == -1 ? clusters : null;
        } catch (IOException | RuntimeException unreadable) {
            return null;
        }
    }

    // ---- buildings ----

    /** The boxes of all the clusters by bucket, to find the cluster a point is in. */
    private static final class Lookup {
        final int[] rects;
        final int[] owner;
        final long[] entries;

        Lookup(Cluster[] clusters) {
            int total = 0;
            for (Cluster cluster : clusters) total += cluster.zones();
            rects = new int[total * 4];
            owner = new int[total];
            int[] xs = new int[total], ys = new int[total], ws = new int[total], hs = new int[total];
            int at = 0;
            for (int number = 0; number < clusters.length; number++) {
                int[] own = clusters[number].rects();
                for (int zone = 0; zone < clusters[number].zones(); zone++, at++) {
                    System.arraycopy(own, zone * 4, rects, at * 4, 4);
                    xs[at] = own[zone * 4];
                    ys[at] = own[zone * 4 + 1];
                    ws[at] = own[zone * 4 + 2];
                    hs[at] = own[zone * 4 + 3];
                    owner[at] = number;
                }
            }
            entries = buckets(xs, ys, ws, hs, total, 0);
        }

        /** The cluster with a box that holds the square, or -1. */
        int at(int x, int y) {
            long bucket = bucketKey(Math.floorDiv(x, BUCKET), Math.floorDiv(y, BUCKET));
            int low = 0, high = entries.length;
            while (low < high) {
                int middle = (low + high) >>> 1;
                if (entries[middle] >>> 21 < bucket) low = middle + 1; else high = middle;
            }
            for (int at = low; at < entries.length && entries[at] >>> 21 == bucket; at++) {
                int zone = (int)(entries[at] & (1 << 21) - 1);
                int rx = rects[zone * 4], ry = rects[zone * 4 + 1];
                if (x >= rx && x < rx + rects[zone * 4 + 2] && y >= ry && y < ry + rects[zone * 4 + 3]) return owner[zone];
            }
            return -1;
        }
    }

    /** The keys of the map buildings in each cluster, for the buildings' epoch now. */
    private void keys(Object meta, Answer answer) throws Throwable {
        buildings.observe();
        if (answer.keys != null && answer.epoch == buildings.epoch()) return;
        if (answer.lookup == null) answer.lookup = new Lookup(answer.clusters);
        var found = new ArrayList<ArrayList<String>>();
        for (int at = 0; at < answer.clusters.length; at++) found.add(new ArrayList<>());
        List<?> map = (List<?>)all.invokeExact(meta);
        for (int index = 0, size = map == null ? 0 : map.size(); index < size; index++) {
            Building building = buildings.describing(map.get(index));
            if (building == null || building.playerBuilt()) continue;
            // The middle as buildings.list has it: (x + x2) / 2 of the box, whose x2 is one past the last square.
            int owner = answer.lookup.at(Math.floorDiv(building.minX() + building.maxX() + 1, 2), Math.floorDiv(building.minY() + building.maxY() + 1, 2));
            if (owner >= 0) found.get(owner).add(building.key());
        }
        answer.keys = new String[found.size()][];
        for (int at = 0; at < answer.keys.length; at++) answer.keys[at] = found.get(at).toArray(new String[0]);
        answer.epoch = buildings.epoch();
    }

    // ---- the answer in Lua ----

    private Object list(Answer answer, boolean withBuildings) throws ReflectiveOperationException {
        Object result = lua.table();
        for (int at = 0; at < answer.clusters.length; at++) {
            Cluster cluster = answer.clusters[at];
            Object entry = lua.table(), rects = lua.table();
            lua.set(entry, "x1", (double)cluster.x1());
            lua.set(entry, "y1", (double)cluster.y1());
            lua.set(entry, "x2", (double)cluster.x2());
            lua.set(entry, "y2", (double)cluster.y2());
            lua.set(entry, "area", (double)cluster.area());
            lua.set(entry, "zones", (double)cluster.zones());
            int[] own = cluster.rects();
            for (int value = 0; value < own.length; value++) lua.set(rects, (double)(value + 1), (double)own[value]);
            lua.set(entry, "rects", rects);
            if (withBuildings) {
                Object keys = lua.table();
                String[] found = answer.keys[at];
                for (int key = 0; key < found.length; key++) lua.set(keys, (double)(key + 1), found[key]);
                lua.set(entry, "buildings", keys);
            }
            lua.set(result, (double)(at + 1), entry);
        }
        return result;
    }
}
