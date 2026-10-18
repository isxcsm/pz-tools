package pzext.api;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;

/**
 * {@code PZExtAPI.zombies.dense}: the places the map puts many zombies (docs/design.md, "Map facts"). The map gives each chunk (8 by 8
 * squares) a zombie intensity from 0 to 255 ({@code IsoMetaChunk.getUnadjustedZombieIntensity}, before the sandbox's population); the
 * chunks at or above {@code min} that touch (8 neighbours) make a group, and the groups of at least {@code minChunks} chunks are listed,
 * the densest first. Read from the meta grid, loaded and unloaded cells alike, once a world and option set, and, on disk, once a map
 * set ({@link MapCache}).
 *
 * <p>A group's {@code x} and {@code y} are the mean of its chunks' middles, {@code r} the largest distance from there to a far corner
 * of one of its chunks; {@code x1..y2} are the squares of the box that holds its chunks (the last square for {@code x2}, {@code y2}).
 * {@code peak} and {@code mean} are the largest and the mean intensity of its chunks. The order is by {@code mean}, then {@code chunks},
 * the larger first, then by place; {@code rank} is the place in that order, 1 the densest.
 *
 * <p>A chunk is read as the game gives it: a chunk the game has made is asked; one it has not yet made gets what the game would give
 * it (the intensity of its cell's header), without making it, so that the walk does not make a chunk object for every chunk of the
 * map. A cell with no header has chunks of intensity 0.
 */
final class DenseZombies {
    /** The most chunks a map's raster may hold: a bound on the work and memory of one call. */
    static final long MAX_RASTER = 1L << 26;
    private static final String AREA = "PZExtAPI.zombies.dense";
    /** The chunks on a side of a cell of the map (IsoMetaCell). */
    private static final int CELL = 32;
    private static final int MAX_CHUNKS = 1 << 24;
    private static final int KEPT = 16;

    private final Kahlua lua;
    private final Game game;
    private final MapCache disk;
    // IsoMetaGrid.getMinX(), getMinY(), gridX(), gridY(), getCellData(x, y); IsoMetaCell.info, hasChunk(x, y), getChunk(x, y);
    // IsoMetaChunk.getUnadjustedZombieIntensity(); LotHeader.getZombieIntensityForChunk(header, x, y).
    private final MethodHandle minX, minY, gridX, gridY, cellAt, info, has, chunk, intensity, header;

    private record Group(double x, double y, double r, int x1, int y1, int x2, int y2, int chunks, int peak, double mean) { }

    private record Wanted(int min, int minChunks) {
        String key() { return min + "\n" + minChunks; }
    }

    // The answers for the meta grid they were made for; another world or grid takes them away.
    private final LinkedHashMap<String, Group[]> kept = new LinkedHashMap<>();
    private Object grid;

    DenseZombies(Kahlua lua, Game game, MapCache disk, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.disk = disk;
        Class<?> meta = Game.type(loader, "zombie.iso.IsoMetaGrid"), cell = Game.type(loader, "zombie.iso.IsoMetaCell");
        Class<?> lot = Game.type(loader, "zombie.iso.LotHeader");
        MethodType number = MethodType.methodType(int.class, Object.class);
        minX = Game.exact(meta.getMethod("getMinX"), number);
        minY = Game.exact(meta.getMethod("getMinY"), number);
        gridX = Game.exact(meta.getMethod("gridX"), number);
        gridY = Game.exact(meta.getMethod("gridY"), number);
        cellAt = Game.exact(meta.getMethod("getCellData", int.class, int.class), MethodType.methodType(Object.class, Object.class, int.class, int.class));
        info = MethodHandles.publicLookup().unreflectGetter(cell.getField("info")).asType(MethodType.methodType(Object.class, Object.class));
        has = Game.exact(cell.getMethod("hasChunk", int.class, int.class), MethodType.methodType(boolean.class, Object.class, int.class, int.class));
        chunk = Game.exact(cell.getMethod("getChunk", int.class, int.class), MethodType.methodType(Object.class, Object.class, int.class, int.class));
        intensity = Game.exact(Game.type(loader, "zombie.iso.IsoMetaChunk").getMethod("getUnadjustedZombieIntensity"), number);
        header = Game.exact(lot.getMethod("getZombieIntensityForChunk", lot, int.class, int.class),
            MethodType.methodType(int.class, Object.class, int.class, int.class));
    }

    /** Sets the function into the zombies' table. */
    void register(Object table) throws ReflectiveOperationException {
        lua.set(table, "dense", lua.function(AREA, arguments -> new Object[] { dense(arguments) }));
    }

    private synchronized Object dense(Object[] arguments) throws ReflectiveOperationException {
        Wanted wanted = wanted(arguments.length > 0 ? arguments[0] : null);
        Object meta = game.metaGrid();
        if (meta == null) return lua.table();
        if (meta != grid) {
            kept.clear();
            grid = meta;
        }
        try {
            Group[] groups = kept.get(wanted.key());
            if (groups == null) {
                groups = read(meta, wanted);
                if (kept.size() >= KEPT) kept.remove(kept.keySet().iterator().next());
                kept.put(wanted.key(), groups);
            }
            return list(groups);
        } catch (ReflectiveOperationException | RuntimeException caller) {
            throw caller;
        } catch (Throwable failure) { throw Game.thrown(failure); }
    }

    private Wanted wanted(Object options) throws ReflectiveOperationException {
        if (!lua.isTable(options)) throw new IllegalArgumentException(AREA + ": options must be a table with min");
        int min = 0, minChunks = 1;
        boolean named = false;
        for (var entry : lua.entries(options)) {
            Object name = entry.getKey(), value = entry.getValue();
            if ("min".equals(name)) {
                min = whole(value, "min", 1, 255);
                named = true;
            } else if ("minChunks".equals(name)) {
                minChunks = whole(value, "minChunks", 1, MAX_CHUNKS);
            } else {
                throw new IllegalArgumentException(AREA + ": options." + name + " is not an option (min, minChunks)");
            }
        }
        if (!named) throw new IllegalArgumentException(AREA + ": options.min must be a whole number from 1 to 255");
        return new Wanted(min, minChunks);
    }

    private static int whole(Object value, String name, int min, int max) {
        if (!(value instanceof Double number) || number != Math.rint(number) || number < min || number > max)
            throw new IllegalArgumentException(AREA + ": options." + name + " must be a whole number from " + min + " to " + max);
        return number.intValue();
    }

    // ---- reading: the disk, or the grid ----

    private Group[] read(Object meta, Wanted wanted) throws Throwable {
        int firstX = (int)minX.invokeExact(meta), firstY = (int)minY.invokeExact(meta);
        int cellsX = (int)gridX.invokeExact(meta), cellsY = (int)gridY.invokeExact(meta);
        if (cellsX <= 0 || cellsY <= 0) return new Group[0];
        if ((long)cellsX * cellsY * CELL * CELL > MAX_RASTER)
            throw new IllegalArgumentException(AREA + ": the map is " + cellsX + " by " + cellsY + " cells; too large to read");
        String question = null, stamp = null;
        if (disk != null) {
            MapCache.Maps maps = disk.maps(false);
            if (maps != null) {
                question = "dense\n" + wanted.key() + '\n' + maps.names();
                stamp = maps.stamp() + "grid " + firstX + ' ' + firstY + ' ' + cellsX + ' ' + cellsY + '\n';
                byte[] saved = disk.read(question, stamp);
                if (saved != null) {
                    Group[] found = decode(saved);
                    if (found != null) return found;
                }
            }
        }
        Group[] made = groups(meta, wanted, firstX, firstY, cellsX, cellsY);
        if (question != null) disk.write(question, stamp, encode(made));
        return made;
    }

    private Group[] groups(Object meta, Wanted wanted, int firstX, int firstY, int cellsX, int cellsY) throws Throwable {
        int width = cellsX * CELL, height = cellsY * CELL, min = wanted.min();
        // The intensity of each chunk that reaches the minimum (0 for the rest), row by row over the whole map.
        byte[] raster = new byte[width * height];
        int dense = 0;
        for (int cellY = 0; cellY < cellsY; cellY++) {
            for (int cellX = 0; cellX < cellsX; cellX++) {
                Object cell = (Object)cellAt.invokeExact(meta, firstX + cellX, firstY + cellY);
                Object lot = cell == null ? null : (Object)info.invokeExact(cell);
                if (lot == null) continue;
                for (int y = 0; y < CELL; y++) {
                    int row = (cellY * CELL + y) * width + cellX * CELL;
                    for (int x = 0; x < CELL; x++) {
                        int value;
                        if ((boolean)has.invokeExact(cell, x, y)) value = (int)intensity.invokeExact((Object)chunk.invokeExact(cell, x, y));
                        else value = (byte)Math.max(0, (int)header.invokeExact(lot, x, y)) & 0xFF;
                        if (value >= min) {
                            raster[row + x] = (byte)value;
                            dense++;
                        }
                    }
                }
            }
        }
        // Groups by flood fill over the 8 neighbours; a chunk is cleared as it is taken.
        var found = new ArrayList<Group>();
        int[] stack = new int[Math.max(dense, 1)], members = new int[Math.max(dense, 1)];
        int half = game.chunkSize / 2, size = game.chunkSize;
        int originX = firstX * CELL, originY = firstY * CELL;
        for (int start = 0; start < raster.length && dense > 0; start++) {
            if (raster[start] == 0) continue;
            int top = 0, count = 0, peak = 0;
            long total = 0;
            int lowX = Integer.MAX_VALUE, lowY = Integer.MAX_VALUE, highX = Integer.MIN_VALUE, highY = Integer.MIN_VALUE;
            stack[top++] = start;
            total += peak = raster[start] & 0xFF;
            raster[start] = 0;
            while (top > 0) {
                int at = stack[--top], column = at % width, line = at / width;
                members[count++] = at;
                lowX = Math.min(lowX, column);
                highX = Math.max(highX, column);
                lowY = Math.min(lowY, line);
                highY = Math.max(highY, line);
                for (int dy = -1; dy <= 1; dy++) {
                    int ny = line + dy;
                    if (ny < 0 || ny >= height) continue;
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = column + dx;
                        if (nx < 0 || nx >= width) continue;
                        int next = ny * width + nx;
                        int value = raster[next] & 0xFF;
                        if (value == 0) continue;
                        total += value;
                        peak = Math.max(peak, value);
                        raster[next] = 0;
                        stack[top++] = next;
                    }
                }
            }
            if (count < wanted.minChunks()) continue;
            double sumX = 0, sumY = 0;
            for (int member = 0; member < count; member++) {
                sumX += (originX + members[member] % width) * (double)size + half;
                sumY += (originY + members[member] / width) * (double)size + half;
            }
            double x = sumX / count, y = sumY / count, far = 0;
            for (int member = 0; member < count; member++) {
                double dx = Math.abs((originX + members[member] % width) * (double)size + half - x) + half;
                double dy = Math.abs((originY + members[member] / width) * (double)size + half - y) + half;
                far = Math.max(far, dx * dx + dy * dy);
            }
            found.add(new Group(x, y, Math.sqrt(far), (originX + lowX) * size, (originY + lowY) * size,
                (originX + highX) * size + size - 1, (originY + highY) * size + size - 1, count, peak, (double)total / count));
        }
        found.sort(Comparator.comparingDouble(Group::mean).reversed().thenComparing(Comparator.comparingInt(Group::chunks).reversed())
            .thenComparingInt(Group::y1).thenComparingInt(Group::x1));
        return found.toArray(new Group[0]);
    }

    // ---- the disk ----

    private static byte[] encode(Group[] groups) throws IOException {
        var bytes = new ByteArrayOutputStream();
        try (var out = new DataOutputStream(bytes)) {
            out.writeInt(groups.length);
            for (Group group : groups) {
                out.writeDouble(group.x());
                out.writeDouble(group.y());
                out.writeDouble(group.r());
                out.writeInt(group.x1());
                out.writeInt(group.y1());
                out.writeInt(group.x2());
                out.writeInt(group.y2());
                out.writeInt(group.chunks());
                out.writeInt(group.peak());
                out.writeDouble(group.mean());
            }
        }
        return bytes.toByteArray();
    }

    /** The groups of a file, or null for one that is not what was written. */
    private static Group[] decode(byte[] data) {
        try (var in = new DataInputStream(new ByteArrayInputStream(data))) {
            int count = in.readInt();
            if (count < 0 || count > data.length) return null;
            Group[] groups = new Group[count];
            for (int at = 0; at < count; at++) {
                groups[at] = new Group(in.readDouble(), in.readDouble(), in.readDouble(), in.readInt(), in.readInt(), in.readInt(), in.readInt(),
                    in.readInt(), in.readInt(), in.readDouble());
            }
            return in.read() == -1 ? groups : null;
        } catch (IOException | RuntimeException unreadable) {
            return null;
        }
    }

    // ---- the answer in Lua ----

    private Object list(Group[] groups) throws ReflectiveOperationException {
        Object result = lua.table();
        for (int at = 0; at < groups.length; at++) {
            Group group = groups[at];
            Object entry = lua.table();
            lua.set(entry, "x", group.x());
            lua.set(entry, "y", group.y());
            lua.set(entry, "r", group.r());
            lua.set(entry, "x1", (double)group.x1());
            lua.set(entry, "y1", (double)group.y1());
            lua.set(entry, "x2", (double)group.x2());
            lua.set(entry, "y2", (double)group.y2());
            lua.set(entry, "chunks", (double)group.chunks());
            lua.set(entry, "peak", (double)group.peak());
            lua.set(entry, "mean", group.mean());
            lua.set(entry, "rank", (double)(at + 1));
            lua.set(result, (double)(at + 1), entry);
        }
        return result;
    }
}
