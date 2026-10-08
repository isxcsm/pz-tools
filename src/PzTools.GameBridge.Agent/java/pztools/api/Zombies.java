package pztools.api;

import java.util.ArrayList;

/**
 * {@code PZToolsAPI.zombies}: a query over the zombies the cell holds, for sensing mods. One pass over the game's list
 * (the loaded, real zombies: a zombie that has not been made yet is not in it), asked each zombie's position through
 * handles that are constants, with nothing allocated for a zombie that is not near, so that a bigger radius costs no more.
 */
final class Zombies {
    static final int MAX_LEVEL = 64, MAX_LIMIT = 64, DEFAULT_LIMIT = 8;
    static final double MAX_RADIUS = 1000;
    private static final String AREA = "PZToolsAPI.zombies.";

    private final Kahlua lua;
    private final Game game;

    Zombies(Kahlua lua, Game game, ClassLoader loader) {
        ZombieReads.use(loader);
        this.lua = lua;
        this.game = game;
    }

    /** Sets this area's functions into its table, replacing those of an earlier API. */
    void register(Object table) throws ReflectiveOperationException {
        lua.set(table, "near", lua.function(AREA + "near", this::near));
    }

    /**
     * {@code zombies.near(x, y, z, radius, limit)}: how many living zombies stand on level {@code z} within {@code radius}
     * squares of the point, and the nearest {@code limit} of them (8 when it is left out, 0 to 64) nearest first, each a
     * table of {@code zombie}, {@code x}, {@code y}, {@code z} and {@code distance}.
     */
    private Object[] near(Object[] arguments) throws Exception {
        String call = AREA + "near";
        double x = Arguments.number(arguments, 0, call, "x", -1e9, 1e9), y = Arguments.number(arguments, 1, call, "y", -1e9, 1e9);
        int level = Arguments.integer(arguments, 2, call, "z", -MAX_LEVEL, MAX_LEVEL);
        double radius = Arguments.number(arguments, 3, call, "radius", 0, MAX_RADIUS);
        int limit = arguments.length > 4 && arguments[4] != null ? Arguments.integer(arguments, 4, call, "limit", 0, MAX_LIMIT) : DEFAULT_LIMIT;
        Object result = lua.table();
        Object cell = game.cell();
        if (cell == null) return new Object[] { 0.0, result };
        Object[] nearest = new Object[limit];
        double[] squared = new double[limit];
        int kept = 0, count = 0;
        try {
            ArrayList<?> zombies = (ArrayList<?>)ZombieReads.Handles.LIST.invokeExact(cell);
            double within = radius * radius;
            for (int at = 0, size = zombies.size(); at < size; at++) {
                Object zombie = zombies.get(at);
                double dx = (float)ZombieReads.Handles.X.invokeExact(zombie) - x, dy = (float)ZombieReads.Handles.Y.invokeExact(zombie) - y;
                double distance = dx * dx + dy * dy;
                if (distance > within || floor((float)ZombieReads.Handles.Z.invokeExact(zombie)) != level
                        || (boolean)ZombieReads.Handles.DEAD.invokeExact(zombie)) continue;
                count++;
                if (limit == 0 || kept == limit && distance >= squared[kept - 1]) continue;
                // Into place among the nearest, dropping the farthest when they are full.
                int place = kept < limit ? kept++ : kept - 1;
                while (place > 0 && squared[place - 1] > distance) { nearest[place] = nearest[place - 1]; squared[place] = squared[place - 1]; place--; }
                nearest[place] = zombie;
                squared[place] = distance;
            }
            for (int index = 0; index < kept; index++) {
                Object entry = lua.table();
                lua.set(entry, "zombie", nearest[index]);
                lua.set(entry, "x", (double)(float)ZombieReads.Handles.X.invokeExact(nearest[index]));
                lua.set(entry, "y", (double)(float)ZombieReads.Handles.Y.invokeExact(nearest[index]));
                lua.set(entry, "z", (double)level);
                lua.set(entry, "distance", Math.sqrt(squared[index]));
                lua.set(result, (double)(index + 1), entry);
            }
        } catch (Exception | Error failure) {
            throw failure;
        } catch (Throwable failure) {
            throw Game.failed(Game.thrown(failure));
        }
        return new Object[] { (double)count, result };
    }

    private static int floor(float value) {
        int whole = (int)value;
        return value < whole ? whole - 1 : whole;
    }
}
