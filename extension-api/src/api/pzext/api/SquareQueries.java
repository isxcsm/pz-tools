package pzext.api;

import java.util.Arrays;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.ThreadLocalRandom;

/**
 * {@code PZExtAPI.squares.nearest}, {@code list} and {@code fit} (docs/design.md, "World queries"): the squares of an area that meet a
 * filter, asked in one call instead of a loop of game calls through Lua. The area is walked once ({@link Areas}), each square is asked
 * through method handles ({@link SquareFilter}), and nothing is allocated for a square: the squares that meet the filter are collected in
 * arrays that grow, and the one list a mod gets is made at the end. The functions share the {@code squares} table with the square watches
 * ({@link SquareWatches}); each area registers its own, so that a fault in one leaves the other.
 */
final class SquareQueries {
    /** The most squares of the shapes of one {@code fit}, and the most squares it asks about in a call. */
    static final int MAX_SHAPE = 10_000, MAX_OFFSET = 4096;
    static final long MAX_FIT_TESTS = 10_000_000;

    private static final String AREA = "PZExtAPI.squares.";
    // In the API's metatable: which API runs these functions now.
    private static final String GENERATION = "squareQueriesGeneration";

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    // The shapes read from the tables of parts, by table (weakly, as the filters are): a table is read once, whatever it holds later.
    private final Map<Object, Shape> shapes = new WeakHashMap<>();
    private long generation;

    SquareQueries(Kahlua lua, Game game, Object meta) throws ReflectiveOperationException {
        SquareFacts.verify();
        this.lua = lua;
        this.game = game;
        this.meta = meta;
    }

    /** No query runs in the environment any more: the functions mods kept refuse to be called. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Throwable; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            if (generation == 0 || generation(lua, meta) != generation)
                throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
            try { return body.call(call, arguments); }
            catch (Exception | Error failure) { throw failure; }
            catch (Throwable failure) { throw Game.thrown(failure); }
        }));
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        function(table, "nearest", this::nearest);
        function(table, "list", this::list);
        function(table, "fit", this::fit);
        function(table, "test", this::test);
        function(table, "why", this::why);
    }

    private static Object argument(Object[] arguments, int at) { return at < arguments.length ? arguments[at] : null; }

    private Areas.Area area(Object[] arguments, int at, String call) throws ReflectiveOperationException {
        return Areas.read(lua, game, argument(arguments, at), call);
    }

    private static SquareFilter plain(SquareFilter filter, String call) {
        if (filter.usesAnchor()) throw new IllegalArgumentException(call + ": filter.room = \"anchor\" is for the parts of squares.fit");
        return filter;
    }

    /** Checks that a table holds no key but the ones given. */
    private void only(Object table, String call, String name, String... allowed) throws ReflectiveOperationException {
        Object extra = unexpected(table, allowed);
        if (extra != null) throw notOneOf(call, name, extra, allowed);
    }

    /** As above, for the table named {@code prefix + name}: the name is made only for a message. */
    private void onlyUnder(Object table, String call, String prefix, String name, String... allowed) throws ReflectiveOperationException {
        Object extra = unexpected(table, allowed);
        if (extra != null) throw notOneOf(call, prefix + name, extra, allowed);
    }

    private void only(Object table, String call, int part, String... allowed) throws ReflectiveOperationException {
        Object extra = unexpected(table, allowed);
        if (extra != null) throw notOneOf(call, partName(part), extra, allowed);
    }

    /** The first key of the table that is not one of the allowed, or null. */
    private Object unexpected(Object table, String[] allowed) throws ReflectiveOperationException {
        outer:
        for (Map.Entry<Object, Object> entry : lua.entries(table)) {
            for (String key : allowed) if (key.equals(entry.getKey())) continue outer;
            return entry.getKey();
        }
        return null;
    }

    private static IllegalArgumentException notOneOf(String call, String name, Object key, String[] allowed) {
        return new IllegalArgumentException(call + ": " + name + "." + key + " is not one of " + String.join(", ", allowed));
    }

    // ---- one square ----

    private static Object square(Object[] arguments, String call) {
        Object square = argument(arguments, 0);
        if (!SquareFacts.SQUARE.isInstance(square)) throw new IllegalArgumentException(call + ": square must be a loaded square (IsoGridSquare)");
        return square;
    }

    /** test(square, filter): whether the square meets the filter. */
    private Object[] test(String call, Object[] arguments) throws Throwable {
        Object square = square(arguments, call);
        SquareFilter filter = plain(SquareFilter.read(lua, game, argument(arguments, 1), call), call);
        return new Object[] { filter.test(square) ? Boolean.TRUE : Boolean.FALSE };
    }

    /** why(square, filter): the key of the first condition the square does not meet (SquareFilter.WHY_ORDER), or nil. */
    private Object[] why(String call, Object[] arguments) throws Throwable {
        Object square = square(arguments, call);
        SquareFilter filter = plain(SquareFilter.read(lua, game, argument(arguments, 1), call), call);
        return new Object[] { filter.why(square) };
    }

    // ---- nearest ----

    private static final class Finder implements Areas.Scan {
        final SquareFilter filter;
        Object found;
        int ring;

        Finder(SquareFilter filter) { this.filter = filter; }

        @Override public boolean at(Object square, int x, int y, int z, int index, int ring) throws Throwable {
            if (square == null || !filter.test(square)) return true;
            found = square;
            this.ring = ring;
            return false;
        }
    }

    private Object[] nearest(String call, Object[] arguments) throws Throwable {
        Areas.Area area = area(arguments, 0, call);
        SquareFilter filter = plain(SquareFilter.read(lua, game, argument(arguments, 1), call), call);
        var finder = new Finder(filter);
        SquareFilter.begin();
        try { area.scan(finder); }
        finally { SquareFilter.end(); }
        if (finder.found == null) return new Object[] { null };
        return area.rings() ? new Object[] { finder.found, (double)finder.ring } : new Object[] { finder.found };
    }

    // ---- list ----

    /** The squares that met the filter, in the area's order, in arrays that grow. */
    private static final class Collector implements Areas.Scan {
        final SquareFilter filter;
        final int stopAt;
        Object[] squares = new Object[16];
        int[] xs = new int[16], ys = new int[16], zs = new int[16];
        int count;

        Collector(SquareFilter filter, int stopAt) { this.filter = filter; this.stopAt = stopAt; }

        @Override public boolean at(Object square, int x, int y, int z, int index, int ring) throws Throwable {
            if (square == null || !filter.test(square)) return true;
            if (count == squares.length) {
                squares = Arrays.copyOf(squares, count * 2);
                xs = Arrays.copyOf(xs, count * 2);
                ys = Arrays.copyOf(ys, count * 2);
                zs = Arrays.copyOf(zs, count * 2);
            }
            squares[count] = square; xs[count] = x; ys[count] = y; zs[count] = z;
            count++;
            return count < stopAt;
        }

    }

    private Object[] list(String call, Object[] arguments) throws Throwable {
        Areas.Area area = area(arguments, 0, call);
        SquareFilter filter = plain(SquareFilter.read(lua, game, argument(arguments, 1), call), call);
        Object options = argument(arguments, 2);
        int limit = Integer.MAX_VALUE, random = -1;
        double[] near = null, joined = null;
        if (options != null) {
            if (!lua.isTable(options)) throw new IllegalArgumentException(call + ": options must be a table");
            only(options, call, "options", "limit", "near", "random", "connected");
            if (lua.get(options, "limit") != null) limit = Areas.whole(lua.get(options, "limit"), call, "options.limit", 0, Integer.MAX_VALUE);
            if (lua.get(options, "random") != null) random = Areas.whole(lua.get(options, "random"), call, "options.random", 0, Integer.MAX_VALUE);
            near = point(options, "near", call);
            joined = point(options, "connected", call);
        }
        if (near != null && random >= 0) throw new IllegalArgumentException(call + ": options.near and options.random cannot be used together");
        // Only a plain limit lets the walk stop early: the others need every square that meets the filter.
        var collector = new Collector(filter, near == null && random < 0 && joined == null ? limit : Integer.MAX_VALUE);
        if (limit == 0) return new Object[] { lua.table() };
        SquareFilter.begin();
        try { area.scan(collector); }
        finally { SquareFilter.end(); }
        int[] chosen = new int[collector.count];
        for (int at = 0; at < chosen.length; at++) chosen[at] = at;
        int size = chosen.length;
        if (joined != null) size = connected(collector, chosen, size, joined[0], joined[1]);
        if (near != null) sortByDistance(collector, chosen, size, near[0], near[1]);
        if (random >= 0) {
            int picks = Math.min(random, size);
            var generator = ThreadLocalRandom.current();
            for (int at = 0; at < picks; at++) {
                int other = at + generator.nextInt(size - at);
                int held = chosen[at]; chosen[at] = chosen[other]; chosen[other] = held;
            }
            size = picks;
        }
        size = Math.min(size, limit);
        Object[] squares = new Object[size];
        for (int at = 0; at < size; at++) squares[at] = collector.squares[chosen[at]];
        return new Object[] { lua.list(Arrays.asList(squares)) };
    }

    /** A point option {@code { x =, y = }}, or null when the option is not there. */
    private double[] point(Object options, String name, String call) throws ReflectiveOperationException {
        Object table = lua.get(options, name);
        if (table == null) return null;
        if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": options." + name + " must be { x =, y = }");
        onlyUnder(table, call, "options.", name, "x", "y");
        return new double[] { SquareFilter.number(lua.get(table, "x"), call, "options.", name, ".x"), SquareFilter.number(lua.get(table, "y"), call, "options.", name, ".y") };
    }

    /** Puts the first {@code size} chosen squares in the order of their distance from the point, the nearer first and the earlier of equals. */
    private static void sortByDistance(Collector found, int[] chosen, int size, double px, double py) {
        long[] keys = new long[size];
        for (int at = 0; at < size; at++) {
            double dx = found.xs[chosen[at]] - px, dy = found.ys[chosen[at]] - py;
            // A non-negative float sorts as its bits do, and the position below it keeps equals in order.
            keys[at] = (long)Float.floatToIntBits((float)(dx * dx + dy * dy)) << 32 | at;
        }
        Arrays.sort(keys);
        int[] before = Arrays.copyOf(chosen, size);
        for (int at = 0; at < size; at++) chosen[at] = before[(int)keys[at]];
    }

    private static long pack(int x, int y, int z) { return (long)(x & 0xFFFFFF) << 30 | (long)(y & 0xFFFFFF) << 6 | z + 32 & 63; }

    /**
     * Keeps, among the first {@code size} chosen squares, those joined by steps the game does not block to the one nearest the point
     * (through squares of the set, same level); returns how many, in the area's order.
     */
    private static int connected(Collector found, int[] chosen, int size, double px, double py) throws Throwable {
        if (size == 0) return 0;
        int capacity = Integer.highestOneBit(size * 2 - 1) << 1;
        long[] keys = new long[capacity];
        int[] slots = new int[capacity];
        Arrays.fill(slots, -1);
        int start = 0;
        double best = Double.MAX_VALUE;
        for (int at = 0; at < size; at++) {
            int square = chosen[at];
            long key = pack(found.xs[square], found.ys[square], found.zs[square]);
            int slot = (int)(key * 0x9E3779B97F4A7C15L >>> 40) & capacity - 1;
            while (slots[slot] != -1 && keys[slot] != key) slot = slot + 1 & capacity - 1;
            keys[slot] = key;
            slots[slot] = at;
            double dx = found.xs[square] - px, dy = found.ys[square] - py, squared = dx * dx + dy * dy;
            if (squared < best) { best = squared; start = at; }
        }
        boolean[] reached = new boolean[size];
        int[] queue = new int[size];
        int head = 0, tail = 0;
        queue[tail++] = start;
        reached[start] = true;
        int[][] steps = { { 0, -1 }, { 0, 1 }, { 1, 0 }, { -1, 0 } };
        while (head < tail) {
            int at = queue[head++], square = chosen[at];
            for (int[] step : steps) {
                long key = pack(found.xs[square] + step[0], found.ys[square] + step[1], found.zs[square]);
                int slot = (int)(key * 0x9E3779B97F4A7C15L >>> 40) & capacity - 1;
                while (slots[slot] != -1 && keys[slot] != key) slot = slot + 1 & capacity - 1;
                int next = slots[slot];
                if (next == -1 || reached[next]) continue;
                if ((boolean)SquareFacts.BLOCKED_TO.invokeExact(found.squares[square], found.squares[chosen[next]])) continue;
                reached[next] = true;
                queue[tail++] = next;
            }
        }
        int kept = 0;
        int[] before = Arrays.copyOf(chosen, size);
        for (int at = 0; at < size; at++) if (reached[at]) chosen[kept++] = before[at];
        return kept;
    }

    // ---- fit ----

    /** The squares of a shape's parts, as offsets from the anchor, each part with its filter. */
    private record Shape(int[][] dxs, int[][] dys, SquareFilter[] filters) { }

    private Shape shape(Object parts, String call) throws Throwable {
        if (lua.isTable(parts)) {
            synchronized (shapes) {
                Shape known = shapes.get(parts);
                if (known != null) return known;
            }
        }
        Shape made = readShape(parts, call);
        synchronized (shapes) { shapes.put(parts, made); }
        return made;
    }

    /** The name of a part in a message; made when one is needed. */
    private static String partName(int part) { return "parts[" + (part + 1) + "]"; }

    /** A whole number of a part's offsets or box (the {@code index}th of the field), named in the message when it is wrong. */
    private static int offset(Object value, String call, int part, String field, int index, int min, int max) {
        if (value instanceof Double number && number == Math.rint(number) && number >= min && number <= max) return number.intValue();
        return Areas.whole(value, call, partName(part) + "." + field + "[" + index + "]", min, max);
    }

    private Shape readShape(Object parts, String call) throws Throwable {
        if (!lua.isTable(parts)) throw new IllegalArgumentException(call + ": parts must be a list of { offsets = {...} or box = {...}, filter = {...} }");
        int count = lua.length(parts);
        if (count == 0) throw new IllegalArgumentException(call + ": parts must hold at least one part");
        var shape = new Shape(new int[count][], new int[count][], new SquareFilter[count]);
        int total = 0;
        for (int part = 0; part < count; part++) {
            Object table = lua.at(parts, part + 1);
            if (!lua.isTable(table)) throw new IllegalArgumentException(call + ": " + partName(part) + " must be a table");
            only(table, call, part, "offsets", "box", "filter");
            Object offsets = lua.get(table, "offsets"), box = lua.get(table, "box");
            if ((offsets == null) == (box == null)) throw new IllegalArgumentException(call + ": " + partName(part) + " must have offsets or box, one of them");
            int[] dx, dy;
            if (offsets != null) {
                if (!lua.isTable(offsets)) throw new IllegalArgumentException(call + ": " + partName(part) + ".offsets must be a list dx1, dy1, dx2, dy2, ...");
                int length = lua.length(offsets);
                if (length == 0 || length % 2 != 0) throw new IllegalArgumentException(call + ": " + partName(part) + ".offsets must be a list dx1, dy1, dx2, dy2, ...");
                if (total + length / 2 > MAX_SHAPE) throw new IllegalArgumentException(call + ": the shape has more than " + MAX_SHAPE + " squares");
                dx = new int[length / 2]; dy = new int[length / 2];
                for (int at = 0; at < dx.length; at++) {
                    dx[at] = offset(lua.at(offsets, at * 2 + 1), call, part, "offsets", at * 2 + 1, -MAX_OFFSET, MAX_OFFSET);
                    dy[at] = offset(lua.at(offsets, at * 2 + 2), call, part, "offsets", at * 2 + 2, -MAX_OFFSET, MAX_OFFSET);
                }
            } else {
                if (!lua.isTable(box)) throw new IllegalArgumentException(call + ": " + partName(part) + ".box must be { x1, y1, x2, y2, step }");
                int x1 = offset(lua.at(box, 1), call, part, "box", 1, -MAX_OFFSET, MAX_OFFSET), y1 = offset(lua.at(box, 2), call, part, "box", 2, -MAX_OFFSET, MAX_OFFSET);
                int x2 = offset(lua.at(box, 3), call, part, "box", 3, -MAX_OFFSET, MAX_OFFSET), y2 = offset(lua.at(box, 4), call, part, "box", 4, -MAX_OFFSET, MAX_OFFSET);
                int step = lua.at(box, 5) == null ? 1 : offset(lua.at(box, 5), call, part, "box", 5, 1, MAX_OFFSET * 2);
                if (x2 < x1 || y2 < y1) throw new IllegalArgumentException(call + ": " + partName(part) + ".box must have x2 >= x1 and y2 >= y1");
                int columns = (x2 - x1) / step + 1, rows = (y2 - y1) / step + 1;
                if ((long)columns * rows + total > MAX_SHAPE) throw new IllegalArgumentException(call + ": the shape has more than " + MAX_SHAPE + " squares");
                dx = new int[columns * rows]; dy = new int[columns * rows];
                int at = 0;
                for (int y = y1; y <= y2; y += step) for (int x = x1; x <= x2; x += step) { dx[at] = x; dy[at++] = y; }
            }
            total += dx.length;
            shape.dxs()[part] = dx;
            shape.dys()[part] = dy;
            shape.filters()[part] = SquareFilter.read(lua, game, lua.get(table, "filter"), call);
        }
        return shape;
    }

    /** Tries shapes at anchors, counting the squares it asks about. */
    private static final class Fitter implements Areas.Scan {
        final Shape shape;
        final Object cell;
        long tests;
        Object found;
        int index;

        Fitter(Shape shape, Object cell) { this.shape = shape; this.cell = cell; }

        @Override public boolean at(Object square, int x, int y, int z, int index, int ring) throws Throwable {
            if (square == null || !fits(square, x, y, z)) return true;
            found = square;
            this.index = index;
            return false;
        }

        boolean fits(Object anchor, int x, int y, int z) throws Throwable {
            for (int part = 0; part < shape.filters().length; part++) {
                int[] dx = shape.dxs()[part], dy = shape.dys()[part];
                SquareFilter filter = shape.filters()[part];
                for (int at = 0; at < dx.length; at++) {
                    if (++tests > MAX_FIT_TESTS) throw new IllegalArgumentException("PZExtAPI.squares.fit: more than " + MAX_FIT_TESTS + " squares to ask about; fewer anchors or a smaller shape");
                    if (!filter.passesAt(cell, x + dx[at], y + dy[at], z, anchor)) return false;
                }
            }
            return true;
        }
    }

    /** The anchors that are loaded, to be tried in an order of their own. */
    private static final class Anchors implements Areas.Scan {
        Object[] squares = new Object[16];
        int[] xs = new int[16], ys = new int[16], zs = new int[16], indexes = new int[16];
        int count;

        @Override public boolean at(Object square, int x, int y, int z, int index, int ring) {
            if (square == null) return true;
            if (count == squares.length) {
                int size = count * 2;
                squares = Arrays.copyOf(squares, size); xs = Arrays.copyOf(xs, size); ys = Arrays.copyOf(ys, size);
                zs = Arrays.copyOf(zs, size); indexes = Arrays.copyOf(indexes, size);
            }
            squares[count] = square; xs[count] = x; ys[count] = y; zs[count] = z; indexes[count] = index;
            count++;
            return true;
        }
    }

    private Object[] fit(String call, Object[] arguments) throws Throwable {
        Areas.Area anchors = area(arguments, 0, call);
        Shape shape = shape(argument(arguments, 1), call);
        Object options = argument(arguments, 2);
        boolean random = false;
        if (options != null) {
            if (!lua.isTable(options)) throw new IllegalArgumentException(call + ": options must be a table");
            only(options, call, "options", "order");
            Object order = lua.get(options, "order");
            if (order != null && !"area".equals(order) && !"random".equals(order))
                throw new IllegalArgumentException(call + ": options.order must be \"area\" or \"random\"");
            random = "random".equals(order);
        }
        var fitter = new Fitter(shape, game.cell());
        SquareFilter.begin();
        try {
            if (!random) anchors.scan(fitter);
            else {
                var all = new Anchors();
                anchors.scan(all);
                var generator = ThreadLocalRandom.current();
                for (int at = all.count - 1; at > 0; at--) {
                    int other = generator.nextInt(at + 1);
                    swap(all.squares, at, other); swap(all.xs, at, other); swap(all.ys, at, other); swap(all.zs, at, other); swap(all.indexes, at, other);
                }
                for (int at = 0; at < all.count; at++)
                    if (fitter.fits(all.squares[at], all.xs[at], all.ys[at], all.zs[at])) {
                        fitter.found = all.squares[at];
                        fitter.index = all.indexes[at];
                        break;
                    }
            }
        } finally { SquareFilter.end(); }
        return fitter.found == null ? new Object[] { null } : new Object[] { fitter.found, (double)fitter.index };
    }

    private static void swap(Object[] values, int first, int second) { Object held = values[first]; values[first] = values[second]; values[second] = held; }

    private static void swap(int[] values, int first, int second) { int held = values[first]; values[first] = values[second]; values[second] = held; }
}
