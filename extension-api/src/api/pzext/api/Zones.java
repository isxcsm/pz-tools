package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.random.RandomGenerator;

/**
 * {@code PZExtAPI.zones.points}: points tried at random in a ring round a point, kept when the map has no building there and its
 * zones are the ones the mod wants (docs/design.md, "Map facts"). A mod that looks for open ground tries a few hundred points, and for
 * each reads the zones at it and at up to 64 points round it for a road; in Java that is a few thousand handle calls and one list of
 * the points kept.
 *
 * <p>The zones are the game's list, the whole map's (zones thousands of squares from the player are in it, unloaded).
 * The points are taken as the mods do: an angle and a radius ({@code lo + random * (hi - lo)}) at random, the point the squares the
 * ring's point falls on; the zones are those at level 0. A road is looked for on eight directions (the diagonals as 0.7 of a step, as
 * the mods have it), every 4 squares.
 *
 * <p>With {@code near} the points are drawn from round the zones of a type instead (a road's: a camp off a road, a site a road comes
 * near): a part of a zone of the type touching the ring (a box, a polyline's segment), by its length, a point of it, and a step of
 * {@code min} to {@code max} squares from it in any direction; kept when it lies in the ring, and no zone of the type is within
 * {@code min}. Where few points of the ring pass (roads are thin), it finds them in a few tries where a random point needs hundreds,
 * and none at once where there are none. The zones of a type are read from the map's list of zones once (again when the list
 * changes).
 */
final class Zones {
    /** The most points a call keeps and the most it tries: a bound on the work of one call, not a rule of play. */
    static final int MAX_COUNT = 1000, MAX_TRIES = 10_000, DEFAULT_TRIES = 300;
    static final String KEY = "zonePointsGeneration";
    private static final String AREA = "PZExtAPI.zones.points";
    private static final double LIMIT = 1e9;
    // The eight directions a road is looked for on.
    private static final double[][] DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } };

    /** What picks the points: the game thread's thread-local random unless a test fixes it. */
    static RandomGenerator random;

    private final Kahlua lua;
    private final Game game;
    private final Generation generation;
    // IsoMetaGrid.getBuildingAt(x, y), getZonesAt(x, y, z, list), its zones; Zone.getType(), its box, whether a polyline and its points.
    private final MethodHandle buildingAt, zonesAt, allZones, type, zoneX, zoneY, zoneW, zoneH, polyline, linePoints;
    // The zones at a point, read into one list of the area's own.
    private final ArrayList<Object> zones = new ArrayList<>();

    /** What a call wants of a point. {@code near}: the zone type points are drawn round (null: at random in the ring). */
    private record Wanted(String[] not, String road, int none, int some, double spacing, String near, int min, int max) { }

    /** A zone of the type, as the points are drawn from it: its box, and for a polyline its points ({@code x0, y0, x1, y1, ...}). */
    private record Shape(int x, int y, int w, int h, int[] line) { }

    // The zones of each type asked, read from the map's list (that list, and its size then).
    private final Map<String, Shape[]> shapes = new HashMap<>();
    private Object shapesOf;
    private int shapesSize = -1;

    Zones(Kahlua lua, Game game, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        generation = new Generation(lua, meta, KEY);
        Class<?> grid = Game.type(loader, "zombie.iso.IsoMetaGrid");
        buildingAt = Game.exact(grid.getMethod("getBuildingAt", int.class, int.class), MethodType.methodType(Object.class, Object.class, int.class, int.class));
        zonesAt = Game.exact(grid.getMethod("getZonesAt", int.class, int.class, int.class, ArrayList.class),
            MethodType.methodType(ArrayList.class, Object.class, int.class, int.class, int.class, ArrayList.class));
        Class<?> zone = Game.type(loader, "zombie.iso.zones.Zone");
        type = Game.exact(zone.getMethod("getType"), MethodType.methodType(String.class, Object.class));
        allZones = java.lang.invoke.MethodHandles.publicLookup().unreflectGetter(grid.getField("zones"))
            .asType(MethodType.methodType(List.class, Object.class));
        MethodType number = MethodType.methodType(int.class, Object.class);
        zoneX = Game.exact(zone.getMethod("getX"), number);
        zoneY = Game.exact(zone.getMethod("getY"), number);
        zoneW = Game.exact(zone.getMethod("getWidth"), number);
        zoneH = Game.exact(zone.getMethod("getHeight"), number);
        polyline = Game.exact(zone.getMethod("isPolyline"), MethodType.methodType(boolean.class, Object.class));
        linePoints = Game.exact(zone.getMethod("getPointsToLua"), MethodType.methodType(List.class, Object.class));
    }

    /** Sets the function into the zones' table. */
    void register(Object table) throws ReflectiveOperationException {
        generation.start();
        lua.set(table, "points", lua.function(AREA, arguments -> {
            generation.check(AREA);
            return new Object[] { points(arguments) };
        }));
    }

    private synchronized Object points(Object[] arguments) throws ReflectiveOperationException {
        double ax = Arguments.number(arguments, 0, AREA, "x", -LIMIT, LIMIT), ay = Arguments.number(arguments, 1, AREA, "y", -LIMIT, LIMIT);
        double lo = Arguments.number(arguments, 2, AREA, "lo", 0, LIMIT), hi = Arguments.number(arguments, 3, AREA, "hi", 0, LIMIT);
        if (lo > hi) throw new IllegalArgumentException(AREA + ": lo must not be more than hi");
        Object options = arguments.length > 4 ? arguments[4] : null;
        if (!lua.isTable(options)) throw new IllegalArgumentException(AREA + ": options must be a table with count");
        int count = integer(options, "count", 1, 1, MAX_COUNT), tries = integer(options, "tries", DEFAULT_TRIES, 1, MAX_TRIES);
        Wanted wanted = wanted(options);
        Object meta = game.metaGrid();
        var kept = new ArrayList<Object>();
        if (meta == null) return lua.list(kept);
        RandomGenerator dice = random != null ? random : ThreadLocalRandom.current();
        var keptX = new int[count];
        var keptY = new int[count];
        int found = 0;
        try {
            // near: the parts of the type's zones a point of the ring may be drawn from (cut to the ring's box), their lengths summed up
            double[][] from = null;
            double[] sums = null;
            if (wanted.near() != null) {
                from = pieces(shapes(meta, wanted.near()), ax, ay, lo - wanted.max(), hi + wanted.max());
                if (from.length == 0) return lua.list(kept);
                sums = new double[from.length];
                double sum = 0;
                for (int at = 0; at < from.length; at++) sums[at] = sum += Math.max(1, from[at][5]);
            }
            for (int attempt = 0; attempt < tries && found < count; attempt++) {
                int x, y;
                if (from != null) {
                    double[] piece = from[pick(sums, dice.nextDouble() * sums[sums.length - 1])];
                    double t = dice.nextDouble(), u = dice.nextDouble();
                    // (a box's part anywhere in it; a polyline's segment along it)
                    double[] at = piece[0] == 0
                        ? new double[] { piece[1] + t * (piece[3] - piece[1]), piece[2] + u * (piece[4] - piece[2]) }
                        : new double[] { piece[1] + t * (piece[3] - piece[1]), piece[2] + t * (piece[4] - piece[2]) };
                    double angle = dice.nextDouble() * 2 * Math.PI, step = wanted.min() + dice.nextDouble() * (wanted.max() - wanted.min());
                    x = (int)Math.floor(at[0] + Math.cos(angle) * step);
                    y = (int)Math.floor(at[1] + Math.sin(angle) * step);
                    double dx = x + 0.5 - ax, dy = y + 0.5 - ay, d = Math.sqrt(dx * dx + dy * dy);
                    if (d < lo || d > hi + 1) continue;
                } else {
                    double angle = dice.nextDouble() * 2 * Math.PI, radius = lo + dice.nextDouble() * (hi - lo);
                    x = (int)Math.floor(ax + Math.cos(angle) * radius);
                    y = (int)Math.floor(ay + Math.sin(angle) * radius);
                }
                if ((Object)buildingAt.invokeExact(meta, x, y) != null) continue;
                if (spaced(keptX, keptY, found, x, y, wanted.spacing())) continue;
                read(meta, x, y);
                if (listed(wanted.not())) continue;
                if (from != null && wanted.min() > 0) {
                    // (none of the type nearer than min: the step took it off the zone it was drawn from, not off another)
                    if (!offRoad(meta, new Wanted(wanted.not(), wanted.near(), wanted.min(), 0, 0, null, 0, 0), x, y)) continue;
                    read(meta, x, y);
                }
                if (wanted.road() != null) {
                    if (!offRoad(meta, wanted, x, y)) continue;
                    read(meta, x, y);
                }
                keptX[found] = x;
                keptY[found++] = y;
                kept.add(point(x, y));
            }
        } catch (Throwable failure) { throw Game.thrown(failure); }
        return lua.list(kept);
    }

    /** The zones of a type in the map's list, read once (again when the list or its size changes). */
    private Shape[] shapes(Object meta, String wanted) throws Throwable {
        List<?> list = (List<?>)allZones.invokeExact(meta);
        if (list != shapesOf || list.size() != shapesSize) {
            shapes.clear();
            shapesOf = list;
            shapesSize = list.size();
        }
        Shape[] known = shapes.get(wanted);
        if (known != null) return known;
        var found = new ArrayList<Shape>();
        for (Object zone : list) {
            if (!wanted.equals((String)type.invokeExact(zone))) continue;
            int x = (int)zoneX.invokeExact(zone), y = (int)zoneY.invokeExact(zone), w = (int)zoneW.invokeExact(zone), h = (int)zoneH.invokeExact(zone);
            int[] line = null;
            if ((boolean)polyline.invokeExact(zone)) {
                List<?> points = (List<?>)linePoints.invokeExact(zone);
                if (points != null && points.size() >= 4) {
                    line = new int[points.size() / 2 * 2];
                    for (int at = 0; at < line.length; at++) line[at] = ((Number)points.get(at)).intValue();
                }
            }
            found.add(new Shape(x, y, w, h, line));
        }
        known = found.toArray(new Shape[0]);
        shapes.put(wanted, known);
        return known;
    }

    /**
     * The parts of the zones a point between {@code lo} and {@code hi} squares of {@code ax, ay} may be drawn from: each zone's box, or
     * each segment of a polyline, cut to the square round the point out to {@code hi} and kept when it reaches into that ring. A part is
     * {@code { 0 for a box | 1 for a segment, x0, y0, x1, y1, length }} (a box's length its longer side).
     */
    private static double[][] pieces(Shape[] all, double ax, double ay, double lo, double hi) {
        double left = ax - hi, top = ay - hi, right = ax + hi, bottom = ay + hi;
        var kept = new ArrayList<double[]>();
        for (Shape shape : all) {
            if (shape.x() > right || shape.x() + shape.w() < left || shape.y() > bottom || shape.y() + shape.h() < top) continue;
            if (shape.line() == null) {
                double x0 = Math.max(shape.x(), left), y0 = Math.max(shape.y(), top);
                double x1 = Math.min(shape.x() + shape.w(), right), y1 = Math.min(shape.y() + shape.h(), bottom);
                if (reaches(x0, y0, x1, y1, ax, ay, lo, hi)) kept.add(new double[] { 0, x0, y0, x1, y1, Math.max(x1 - x0, y1 - y0) });
                continue;
            }
            int[] line = shape.line();
            for (int at = 0; at + 3 < line.length; at += 2) {
                double[] cut = clip(line[at], line[at + 1], line[at + 2], line[at + 3], left, top, right, bottom);
                if (cut == null) continue;
                double x0 = Math.min(cut[0], cut[2]), y0 = Math.min(cut[1], cut[3]), x1 = Math.max(cut[0], cut[2]), y1 = Math.max(cut[1], cut[3]);
                if (reaches(x0, y0, x1, y1, ax, ay, lo, hi))
                    kept.add(new double[] { 1, cut[0], cut[1], cut[2], cut[3], Math.hypot(cut[2] - cut[0], cut[3] - cut[1]) });
            }
        }
        return kept.toArray(new double[0][]);
    }

    /** Whether a box comes between {@code lo} and {@code hi} squares of the point (some of it in that ring). */
    private static boolean reaches(double x0, double y0, double x1, double y1, double ax, double ay, double lo, double hi) {
        double nx = Math.max(Math.max(x0 - ax, 0), ax - x1), ny = Math.max(Math.max(y0 - ay, 0), ay - y1);
        double fx = Math.max(Math.abs(x0 - ax), Math.abs(x1 - ax)), fy = Math.max(Math.abs(y0 - ay), Math.abs(y1 - ay));
        return Math.hypot(nx, ny) <= hi && Math.hypot(fx, fy) >= lo;
    }

    /** A segment cut to a box (Liang-Barsky): its ends {@code x0, y0, x1, y1}, or null when none of it is in the box. */
    private static double[] clip(double x0, double y0, double x1, double y1, double left, double top, double right, double bottom) {
        double dx = x1 - x0, dy = y1 - y0, from = 0, to = 1;
        double[] p = { -dx, dx, -dy, dy }, q = { x0 - left, right - x0, y0 - top, bottom - y0 };
        for (int at = 0; at < 4; at++) {
            if (p[at] == 0) {
                if (q[at] < 0) return null;
            } else {
                double r = q[at] / p[at];
                if (p[at] < 0) from = Math.max(from, r); else to = Math.min(to, r);
            }
        }
        if (from > to) return null;
        return new double[] { x0 + from * dx, y0 + from * dy, x0 + to * dx, y0 + to * dy };
    }

    /** The index of the sums (rising) the value falls under. */
    private static int pick(double[] sums, double value) {
        int low = 0, high = sums.length - 1;
        while (low < high) {
            int middle = (low + high) >>> 1;
            if (sums[middle] <= value) low = middle + 1; else high = middle;
        }
        return low;
    }

    /** Whether a kept point is nearer than the spacing. */
    private static boolean spaced(int[] xs, int[] ys, int count, int x, int y, double spacing) {
        if (spacing <= 0) return false;
        for (int at = 0; at < count; at++) {
            double dx = xs[at] - x, dy = ys[at] - y;
            if (dx * dx + dy * dy < spacing * spacing) return true;
        }
        return false;
    }

    /** Reads the zones at the point (level 0) into the area's list. */
    private void read(Object meta, int x, int y) throws Throwable {
        zones.clear();
        ArrayList<?> found = (ArrayList<?>)zonesAt.invokeExact(meta, x, y, 0, zones);
        if (found != zones) { zones.clear(); zones.addAll(found); }
    }

    /** Whether one of the zones read has one of the types. */
    private boolean listed(String[] types) throws Throwable {
        if (types.length == 0) return false;
        for (int at = 0, size = zones.size(); at < size; at++) {
            String name = (String)type.invokeExact(zones.get(at));
            for (String wanted : types) if (wanted.equals(name)) return true;
        }
        return false;
    }

    /**
     * Whether a road passes where the mod wants it: none of the type within {@code none} squares (looked for every 4 squares on
     * eight directions), and, when {@code some} asks for one, a zone of the type further out, up to {@code some}.
     */
    private boolean offRoad(Object meta, Wanted wanted, int x, int y) throws Throwable {
        int step = 4;
        for (int radius = step; radius <= wanted.none(); radius += step)
            if (roadOn(meta, wanted.road(), x, y, radius)) return false;
        if (wanted.some() <= wanted.none()) return true;
        for (int radius = (wanted.none() / step + 1) * step; radius <= wanted.some(); radius += step)
            if (roadOn(meta, wanted.road(), x, y, radius)) return true;
        return false;
    }

    /** Whether a zone of the type lies at the eight points the radius away. */
    private boolean roadOn(Object meta, String road, int x, int y, int radius) throws Throwable {
        for (double[] direction : DIRECTIONS) {
            read(meta, (int)Math.floor(x + direction[0] * radius), (int)Math.floor(y + direction[1] * radius));
            for (int at = 0, size = zones.size(); at < size; at++) if (road.equals((String)type.invokeExact(zones.get(at)))) return true;
        }
        return false;
    }

    /** A point kept: its place and the types of the zones at it (already read). */
    private Object point(int x, int y) throws Throwable {
        Object result = lua.table(), types = lua.table();
        int number = 0;
        for (int at = 0, size = zones.size(); at < size; at++) {
            String name = (String)type.invokeExact(zones.get(at));
            if (name != null) lua.set(types, (double)(++number), name);
        }
        lua.set(result, "x", (double)x);
        lua.set(result, "y", (double)y);
        lua.set(result, "zones", types);
        return result;
    }

    private int integer(Object options, String name, int fallback, int min, int max) throws ReflectiveOperationException {
        Object value = lua.get(options, name);
        if (value == null) return fallback;
        if (!(value instanceof Double number) || number != Math.rint(number) || number < min || number > max)
            throw new IllegalArgumentException(AREA + ": options." + name + " must be a whole number from " + min + " to " + max);
        return number.intValue();
    }

    private Wanted wanted(Object options) throws ReflectiveOperationException {
        String[] not = new String[0];
        Object list = lua.get(options, "not");
        if (list != null) {
            if (!lua.isTable(list)) throw new IllegalArgumentException(AREA + ": options.not must be a list of zone types");
            not = strings(list, "options.not");
        }
        String road = null;
        int none = 0, some = 0;
        Object roads = lua.get(options, "road");
        if (roads != null) {
            if (!lua.isTable(roads) || !(lua.get(roads, "type") instanceof String named))
                throw new IllegalArgumentException(AREA + ": options.road must be a table with the zone type");
            road = named;
            none = integer(roads, "none", 0, 0, 1000);
            some = integer(roads, "some", 0, 0, 1000);
        }
        Object spacing = lua.get(options, "spacing");
        if (spacing != null && (!(spacing instanceof Double number) || !(number >= 0 && number <= LIMIT)))
            throw new IllegalArgumentException(AREA + ": options.spacing must be a number from 0 to " + LIMIT);
        String near = null;
        int min = 0, max = 0;
        Object nearby = lua.get(options, "near");
        if (nearby != null) {
            if (!lua.isTable(nearby) || !(lua.get(nearby, "type") instanceof String named))
                throw new IllegalArgumentException(AREA + ": options.near must be a table with the zone type");
            near = named;
            min = integer(nearby, "min", 0, 0, 1000);
            max = integer(nearby, "max", -1, 1, 1000);
            if (max < 1) throw new IllegalArgumentException(AREA + ": options.near.max must be a whole number from 1 to 1000");
            if (max < min) throw new IllegalArgumentException(AREA + ": options.near.max must not be less than min");
        }
        return new Wanted(not, road, none, some, spacing == null ? 0 : (Double)spacing, near, min, max);
    }

    private String[] strings(Object list, String name) throws ReflectiveOperationException {
        int length;
        try { length = lua.length(list); } catch (Throwable failure) { throw Game.thrown(failure); }
        List<String> result = new ArrayList<>();
        for (int at = 1; at <= length; at++) {
            if (!(lua.get(list, (double)at) instanceof String text)) throw new IllegalArgumentException(AREA + ": " + name + " must be a list of strings");
            result.add(text);
        }
        return result.toArray(new String[0]);
    }
}
