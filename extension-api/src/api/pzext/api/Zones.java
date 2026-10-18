package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.random.RandomGenerator;

/**
 * {@code PZExtAPI.zones.points}: points tried at random in a ring round a point, kept when the map has no building there and its
 * zones are the ones the mod wants (docs/design.md, "Map facts"). A mod that looks for open ground tries a few hundred points, and for
 * each reads the zones at it and at up to 64 points round it for a road; in Java that is a few thousand handle calls and one list of
 * the points kept.
 *
 * <p>The map's zones are kept by the game for the cells it has loaded, so a point far off is judged by what the game knows of it.
 * The points are taken as the mods do: an angle and a radius ({@code lo + random * (hi - lo)}) at random, the point the squares the
 * ring's point falls on; the zones are those at level 0. A road is looked for on eight directions (the diagonals as 0.7 of a step, as
 * the mods have it), every 4 squares.
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
    // IsoMetaGrid.getBuildingAt(x, y), getZonesAt(x, y, z, list); Zone.getType().
    private final MethodHandle buildingAt, zonesAt, type;
    // The zones at a point, read into one list of the area's own.
    private final ArrayList<Object> zones = new ArrayList<>();

    /** What a call wants of a point. */
    private record Wanted(String[] not, String road, int none, int some, double spacing) { }

    Zones(Kahlua lua, Game game, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        generation = new Generation(lua, meta, KEY);
        Class<?> grid = Game.type(loader, "zombie.iso.IsoMetaGrid");
        buildingAt = Game.exact(grid.getMethod("getBuildingAt", int.class, int.class), MethodType.methodType(Object.class, Object.class, int.class, int.class));
        zonesAt = Game.exact(grid.getMethod("getZonesAt", int.class, int.class, int.class, ArrayList.class),
            MethodType.methodType(ArrayList.class, Object.class, int.class, int.class, int.class, ArrayList.class));
        type = Game.exact(Game.type(loader, "zombie.iso.zones.Zone").getMethod("getType"), MethodType.methodType(String.class, Object.class));
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
            for (int attempt = 0; attempt < tries && found < count; attempt++) {
                double angle = dice.nextDouble() * 2 * Math.PI, radius = lo + dice.nextDouble() * (hi - lo);
                int x = (int)Math.floor(ax + Math.cos(angle) * radius), y = (int)Math.floor(ay + Math.sin(angle) * radius);
                if ((Object)buildingAt.invokeExact(meta, x, y) != null) continue;
                if (spaced(keptX, keptY, found, x, y, wanted.spacing())) continue;
                read(meta, x, y);
                if (listed(wanted.not())) continue;
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
        return new Wanted(not, road, none, some, spacing == null ? 0 : (Double)spacing);
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
