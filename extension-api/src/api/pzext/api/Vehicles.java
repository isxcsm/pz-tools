package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Set;
import java.util.concurrent.ThreadLocalRandom;

/**
 * {@code PZExtAPI.vehicles.near}: the vehicles of the game's current cell within a distance of a point (docs/design.md, "Map facts"),
 * nearest first. A mod that listens for car alarms asks it each second; in Lua it is a walk of the cell's vehicle set through Kahlua.
 *
 * <p>Distance is straight in the plane. A vehicle counts when its level is the asked one or the one above or below it: the game
 * keeps a vehicle's height as a fraction of a level, and a mod that asks about a floor wants the cars it can hear or see there.
 * The cell's vehicles are those of the loaded chunks.
 *
 * <p>{@code PZExtAPI.vehicles.damage}: a vehicle's parts set in one call (docs/design.md, "Map facts"): every part that
 * holds an item given a condition in a range, some parts an exact one, some parts' items taken out (a wheel's tire: the
 * vehicle stands on the rim, as the game's own removal leaves it), broken glass on the vehicle's square. Each change is
 * sent to the clients as the game's mechanics send it, and the part's stats follow its item as after a repair. A mod that
 * puts a wrecked vehicle in the world states the wreck; the walk of the parts and the game calls of each are Java's.
 */
final class Vehicles {
    /** The widest radius a call takes: a bound on the work of one call, not a rule of play. */
    static final double MAX_RADIUS = 10_000;
    static final String KEY = "vehiclesNearGeneration";
    private static final String AREA = "PZExtAPI.vehicles.near";
    private static final double LIMIT = 1e9;
    private static final String DAMAGE = "PZExtAPI.vehicles.damage";
    /** The model a wheel shows while it has its tire (the game's tire removal hides it). */
    private static final String TIRE_MODEL = "InflatedTirePlusWheel";

    private final Kahlua lua;
    private final Game game;
    private final Generation generation;
    // IsoCell.getVehicles(); IsoMovingObject.getX(), getY(), getZ() of a vehicle.
    private final MethodHandle vehicles, atX, atY, atZ;
    private final Class<?> vehicleType;
    // BaseVehicle.getParts(), transmitPartCondition(part), transmitPartItem(part), setTireRemoved(wheel, removed), getSquare();
    // VehicleParts.getPartCount(), getPartByIndex(i), getPartById(id); VehiclePart.getCondition(), setCondition(c),
    // getInventoryItem(), setInventoryItem(item), doInventoryItemStats(item, skill), getMechanicSkillInstaller(),
    // getWheelIndex(), setModelVisible(model, visible); IsoGridSquare.addBrokenGlass().
    private final MethodHandle parts, sendCondition, sendItem, tireRemoved, squareOf, partCount, partAt, partById, condition,
        setCondition, itemOf, setItem, itemStats, installer, wheel, modelVisible, addGlass;

    private record Near(double distance, Object vehicle) { }

    Vehicles(Kahlua lua, Game game, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        generation = new Generation(lua, meta, KEY);
        Class<?> vehicle = Game.type(loader, "zombie.vehicles.BaseVehicle");
        vehicles = Game.exact(Game.type(loader, "zombie.iso.IsoCell").getMethod("getVehicles"), MethodType.methodType(Set.class, Object.class));
        MethodType coordinate = MethodType.methodType(float.class, Object.class);
        atX = Game.exact(vehicle.getMethod("getX"), coordinate);
        atY = Game.exact(vehicle.getMethod("getY"), coordinate);
        atZ = Game.exact(vehicle.getMethod("getZ"), coordinate);
        vehicleType = vehicle;
        Class<?> list = Game.type(loader, "zombie.vehicles.VehicleParts"), part = Game.type(loader, "zombie.vehicles.VehiclePart");
        Class<?> item = Game.type(loader, "zombie.inventory.InventoryItem"), square = Game.type(loader, "zombie.iso.IsoGridSquare");
        MethodType toObject = MethodType.methodType(Object.class, Object.class), onPart = MethodType.methodType(void.class, Object.class, Object.class);
        MethodType toInt = MethodType.methodType(int.class, Object.class);
        parts = Game.exact(vehicle.getMethod("getParts"), toObject);
        sendCondition = Game.exact(vehicle.getMethod("transmitPartCondition", part), onPart);
        sendItem = Game.exact(vehicle.getMethod("transmitPartItem", part), onPart);
        tireRemoved = Game.exact(vehicle.getMethod("setTireRemoved", int.class, boolean.class),
            MethodType.methodType(void.class, Object.class, int.class, boolean.class));
        squareOf = Game.exact(vehicle.getMethod("getSquare"), toObject);
        partCount = Game.exact(list.getMethod("getPartCount"), toInt);
        partAt = Game.exact(list.getMethod("getPartByIndex", int.class), MethodType.methodType(Object.class, Object.class, int.class));
        partById = Game.exact(list.getMethod("getPartById", String.class), MethodType.methodType(Object.class, Object.class, String.class));
        condition = Game.exact(part.getMethod("getCondition"), toInt);
        setCondition = Game.exact(part.getMethod("setCondition", int.class), MethodType.methodType(void.class, Object.class, int.class));
        itemOf = Game.exact(part.getMethod("getInventoryItem"), toObject);
        setItem = Game.exact(part.getMethod("setInventoryItem", item), onPart);
        itemStats = Game.exact(part.getMethod("doInventoryItemStats", item, int.class),
            MethodType.methodType(void.class, Object.class, Object.class, int.class));
        installer = Game.exact(part.getMethod("getMechanicSkillInstaller"), toInt);
        wheel = Game.exact(part.getMethod("getWheelIndex"), toInt);
        modelVisible = Game.exact(part.getMethod("setModelVisible", String.class, boolean.class),
            MethodType.methodType(void.class, Object.class, String.class, boolean.class));
        addGlass = Game.exact(square.getMethod("addBrokenGlass"), toObject);
    }

    /** Sets the function into the vehicles' table. */
    void register(Object table) throws ReflectiveOperationException {
        generation.start();
        lua.set(table, "near", lua.function(AREA, arguments -> {
            generation.check(AREA);
            return new Object[] { near(arguments) };
        }));
        lua.set(table, "damage", lua.function(DAMAGE, arguments -> new Object[] { (double)damage(arguments) }));
    }

    /**
     * {@code damage(vehicle, spec)}: {@code spec.condition = { least, most }} every part that holds an item, a whole condition
     * between (both included); {@code spec.parts = { [id] = condition }} those parts, after the range; {@code spec.remove = { id,
     * ... }} those parts' items taken out (their condition 0); {@code spec.glass = true} broken glass on the vehicle's square.
     * Returns how many part changes were made. A part id the vehicle lacks is passed over (vehicles differ).
     */
    private int damage(Object[] arguments) throws ReflectiveOperationException {
        Object vehicle = arguments.length > 0 ? arguments[0] : null;
        if (!vehicleType.isInstance(vehicle)) throw new IllegalArgumentException(DAMAGE + ": vehicle must be a vehicle");
        Object spec = arguments.length > 1 ? arguments[1] : null;
        if (!lua.isTable(spec)) throw new IllegalArgumentException(DAMAGE + ": spec must be a table");
        Object range = lua.get(spec, "condition"), exact = lua.get(spec, "parts"), remove = lua.get(spec, "remove");
        int least = 0, most = 0;
        if (range != null) {
            if (!lua.isTable(range)) throw new IllegalArgumentException(DAMAGE + ": condition must be { least, most }");
            least = conditionOf(lua.getAt(range, 1), "condition[1]");
            most = conditionOf(lua.getAt(range, 2), "condition[2]");
            if (least > most) throw new IllegalArgumentException(DAMAGE + ": condition[1] must not be above condition[2]");
        }
        if (exact != null && !lua.isTable(exact)) throw new IllegalArgumentException(DAMAGE + ": parts must be a table of id = condition");
        if (remove != null && !lua.isTable(remove)) throw new IllegalArgumentException(DAMAGE + ": remove must be a list of part ids");
        int changed = 0;
        try {
            Object list = (Object)parts.invokeExact(vehicle);
            if (list == null) return 0;
            if (range != null) {
                int count = (int)partCount.invokeExact(list);
                var random = ThreadLocalRandom.current();
                for (int index = 0; index < count; index++) {
                    Object part = (Object)partAt.invokeExact(list, index);
                    if (part == null || (Object)itemOf.invokeExact(part) == null) continue;
                    condition(vehicle, part, least == most ? least : random.nextInt(least, most + 1));
                    changed++;
                }
            }
            if (exact != null) {
                for (var entry : lua.entries(exact)) {
                    if (!(entry.getKey() instanceof String id)) throw new IllegalArgumentException(DAMAGE + ": parts must be keyed by part id");
                    int value = conditionOf(entry.getValue(), "parts." + id);
                    Object part = (Object)partById.invokeExact(list, id);
                    if (part == null) continue;
                    condition(vehicle, part, value);
                    changed++;
                }
            }
            if (remove != null) {
                for (var entry : lua.entries(remove)) {
                    if (!(entry.getValue() instanceof String id)) throw new IllegalArgumentException(DAMAGE + ": remove must be a list of part ids");
                    Object part = (Object)partById.invokeExact(list, id);
                    if (part == null || (Object)itemOf.invokeExact(part) == null) continue;
                    setItem.invokeExact(part, (Object)null);
                    setCondition.invokeExact(part, 0);
                    int at = (int)wheel.invokeExact(part);
                    if (at >= 0) {
                        modelVisible.invokeExact(part, TIRE_MODEL, false);
                        tireRemoved.invokeExact(vehicle, at, true);
                    }
                    sendItem.invokeExact(vehicle, part);
                    sendCondition.invokeExact(vehicle, part);
                    changed++;
                }
            }
            if (Boolean.TRUE.equals(lua.get(spec, "glass"))) {
                Object square = (Object)squareOf.invokeExact(vehicle);
                if (square != null) { Object glass = (Object)addGlass.invokeExact(square); }
            }
        } catch (ReflectiveOperationException | RuntimeException failure) { throw failure; }
        catch (Throwable failure) { throw Game.thrown(failure); }
        return changed;
    }

    /** A part's condition set, its stats made to follow its item (as the game's mechanics do), and sent. */
    private void condition(Object vehicle, Object part, int value) throws Throwable {
        setCondition.invokeExact(part, value);
        Object item = (Object)itemOf.invokeExact(part);
        if (item != null) itemStats.invokeExact(part, item, (int)installer.invokeExact(part));
        sendCondition.invokeExact(vehicle, part);
    }

    private static int conditionOf(Object value, String name) {
        if (!(value instanceof Number number) || number.doubleValue() != Math.rint(number.doubleValue())
                || number.doubleValue() < 0 || number.doubleValue() > 100)
            throw new IllegalArgumentException(DAMAGE + ": " + name + " must be a whole number from 0 to 100");
        return (int)number.doubleValue();
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
        for (int index = 0; index < found.size(); index++) lua.setAt(result, index + 1, found.get(index).vehicle());
        return result;
    }
}
