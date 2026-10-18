package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Set;

/**
 * {@code PZExtAPI.vehicles.near}: the vehicles of the game's current cell within a distance of a point (docs/design.md, "Map facts"),
 * nearest first. A mod that listens for car alarms asks it each second; in Lua it is a walk of the cell's vehicle set through Kahlua.
 *
 * <p>Distance is straight in the plane. A vehicle counts when its level is the asked one or the one above or below it: the game
 * keeps a vehicle's height as a fraction of a level, and a mod that asks about a floor wants the cars it can hear or see there.
 * The cell's vehicles are those of the loaded chunks.
 */
final class Vehicles {
    /** The widest radius a call takes: a bound on the work of one call, not a rule of play. */
    static final double MAX_RADIUS = 10_000;
    private static final String AREA = "PZExtAPI.vehicles.near";
    private static final double LIMIT = 1e9;

    private final Kahlua lua;
    private final Game game;
    // IsoCell.getVehicles(); IsoMovingObject.getX(), getY(), getZ() of a vehicle.
    private final MethodHandle vehicles, atX, atY, atZ;

    private record Near(double distance, Object vehicle) { }

    Vehicles(Kahlua lua, Game game, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        Class<?> vehicle = Game.type(loader, "zombie.vehicles.BaseVehicle");
        vehicles = Game.exact(Game.type(loader, "zombie.iso.IsoCell").getMethod("getVehicles"), MethodType.methodType(Set.class, Object.class));
        MethodType coordinate = MethodType.methodType(float.class, Object.class);
        atX = Game.exact(vehicle.getMethod("getX"), coordinate);
        atY = Game.exact(vehicle.getMethod("getY"), coordinate);
        atZ = Game.exact(vehicle.getMethod("getZ"), coordinate);
    }

    /** Sets the function into the vehicles' table. */
    void register(Object table) throws ReflectiveOperationException {
        lua.set(table, "near", lua.function(AREA, arguments -> new Object[] { near(arguments) }));
    }

    private Object near(Object[] arguments) throws ReflectiveOperationException {
        double x = Arguments.number(arguments, 0, AREA, "x", -LIMIT, LIMIT), y = Arguments.number(arguments, 1, AREA, "y", -LIMIT, LIMIT);
        int z = Arguments.integer(arguments, 2, AREA, "z", SquareWatches.MIN_LEVEL, SquareWatches.MAX_LEVEL);
        double r = Arguments.number(arguments, 3, AREA, "r", 0, MAX_RADIUS);
        Object cell = game.cell();
        var found = new ArrayList<Near>();
        if (cell != null) {
            try {
                Set<?> all = (Set<?>)vehicles.invokeExact(cell);
                if (all != null) {
                    for (Object vehicle : all) {
                        double dx = (float)atX.invokeExact(vehicle) - x, dy = (float)atY.invokeExact(vehicle) - y;
                        double distance = Math.sqrt(dx * dx + dy * dy);
                        if (distance > r || Math.abs(Math.floor((float)atZ.invokeExact(vehicle)) - z) > 1) continue;
                        found.add(new Near(distance, vehicle));
                    }
                }
            } catch (Throwable failure) { throw Game.thrown(failure); }
        }
        found.sort(Comparator.comparingDouble(Near::distance));
        Object result = lua.table();
        for (int index = 0; index < found.size(); index++) lua.set(result, (double)(index + 1), found.get(index).vehicle());
        return result;
    }
}
