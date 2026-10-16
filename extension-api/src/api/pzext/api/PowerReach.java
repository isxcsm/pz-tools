package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import pzext.api.Reach.Seed;

/**
 * The generators and the power questions of the game as constant method handles (see {@link Reach}), for the power
 * networks' hooks and frames: a generator's state, its updates, and the questions the networks ask again with themselves
 * silent. Made when the power networks are (a game without them does not take the other handles down).
 */
final class PowerReach {
    private static final ClassLoader LOADER = Seed.get();
    private static final MethodType OBJECT_OF_OBJECT = MethodType.methodType(Object.class, Object.class);

    // IsoGenerator: switched on, fuel, condition, what it burns an hour, its base consumption, what it was set to burn, the
    // hour it burned up to; and setting those. IsoGridSquare.getGenerator.
    static final MethodHandle ACTIVATED, FUEL, CONDITION, PER_HOUR, BASE_POWER, USING, LAST_HOUR, SET_USING, SET_ACTIVATED,
        SET_LAST_HOUR, GENERATOR_OF;
    // The questions the networks ask again with themselves silent, and the objects a power question is about.
    static final MethodHandle CONTAINER_POWERED, SWITCH_POWERED, DEVICE_POWERED, SQUARE_POWERED, CONTAINER_SQUARE,
        BATTERY, DEVICE_PARENT, CONTAINER_PARENT;
    // IsoGenerator.getGeneratorItemType (the item a generator was placed from); null for a game without it.
    static final MethodHandle ITEM_TYPE;

    static {
        try {
            var lookup = MethodHandles.lookup();
            Class<?> object = type("zombie.iso.IsoObject"), square = type("zombie.iso.IsoGridSquare");
            Class<?> generator = type("zombie.iso.objects.IsoGenerator");
            Class<?> container = type("zombie.inventory.ItemContainer"), device = type("zombie.radio.devices.DeviceData");
            ACTIVATED = Reach.handle(lookup, generator.getMethod("isActivated"), MethodType.methodType(boolean.class, Object.class));
            FUEL = Reach.handle(lookup, generator.getMethod("getFuel"), MethodType.methodType(float.class, Object.class));
            CONDITION = Reach.handle(lookup, generator.getMethod("getCondition"), MethodType.methodType(int.class, Object.class));
            PER_HOUR = Reach.handle(lookup, generator.getMethod("getTotalPowerUsing"), MethodType.methodType(float.class, Object.class));
            BASE_POWER = lookup.unreflectGetter(Reach.open(generator.getDeclaredField("GeneratorBasePowerConsumption")))
                .asType(MethodType.methodType(float.class));
            USING = Reach.field(lookup, Reach.open(generator.getDeclaredField("totalPowerUsing")), MethodType.methodType(float.class, Object.class));
            Field lastHour = Reach.open(generator.getDeclaredField("lastHour"));
            LAST_HOUR = Reach.field(lookup, lastHour, MethodType.methodType(int.class, Object.class));
            SET_LAST_HOUR = lookup.unreflectSetter(lastHour).asType(MethodType.methodType(void.class, Object.class, int.class));
            SET_USING = Reach.handle(lookup, generator.getMethod("setTotalPowerUsing", float.class),
                MethodType.methodType(void.class, Object.class, float.class));
            SET_ACTIVATED = Reach.handle(lookup, generator.getMethod("setActivated", boolean.class),
                MethodType.methodType(void.class, Object.class, boolean.class));
            GENERATOR_OF = Reach.handle(lookup, square.getMethod("getGenerator"), OBJECT_OF_OBJECT);
            CONTAINER_POWERED = Reach.handle(lookup, container.getMethod("isObjectPowered", object, boolean.class),
                MethodType.methodType(boolean.class, Object.class, boolean.class));
            SWITCH_POWERED = Reach.handle(lookup, Reach.open(type("zombie.iso.objects.IsoLightSwitch").getDeclaredMethod("hasElectricityAround")),
                MethodType.methodType(boolean.class, Object.class));
            DEVICE_POWERED = Reach.handle(lookup, device.getMethod("canBePoweredHere"), MethodType.methodType(boolean.class, Object.class));
            SQUARE_POWERED = Reach.handle(lookup, square.getMethod("haveElectricity"), MethodType.methodType(boolean.class, Object.class));
            CONTAINER_SQUARE = Reach.handle(lookup, container.getMethod("getSourceGrid"), OBJECT_OF_OBJECT);
            BATTERY = Reach.handle(lookup, device.getMethod("getIsBatteryPowered"), MethodType.methodType(boolean.class, Object.class));
            DEVICE_PARENT = Reach.handle(lookup, device.getMethod("getParent"), OBJECT_OF_OBJECT);
            CONTAINER_PARENT = Reach.handle(lookup, container.getMethod("getParent"), OBJECT_OF_OBJECT);
            ITEM_TYPE = itemType(lookup, generator);
        } catch (ReflectiveOperationException failure) {
            throw new ExceptionInInitializerError(failure);
        }
    }

    private PowerReach() { }

    /** Makes the handles (a game they cannot be made from gets a ReflectiveOperationException, as the other lookups give). */
    static void verify() throws ReflectiveOperationException {
        try { if (ACTIVATED == null) throw new IllegalStateException(); }
        catch (ExceptionInInitializerError | NoClassDefFoundError unreadable) {
            throw new ReflectiveOperationException("the game's generators cannot be called: " + unreadable,
                unreadable.getCause() != null ? unreadable.getCause() : unreadable);
        }
    }

    private static Class<?> type(String name) throws ClassNotFoundException { return Class.forName(name, false, LOADER); }

    private static MethodHandle itemType(MethodHandles.Lookup lookup, Class<?> generator) throws IllegalAccessException {
        try { return Reach.handle(lookup, generator.getMethod("getGeneratorItemType"), OBJECT_OF_OBJECT); }
        catch (NoSuchMethodException none) { return null; }
    }

    // Calls that fail as Method.invoke does (the game's exception in an InvocationTargetException): static, so that the
    // handles stay constants.

    static boolean activated(Object generator) throws ReflectiveOperationException {
        try { return (boolean)ACTIVATED.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static float fuel(Object generator) throws ReflectiveOperationException {
        try { return (float)FUEL.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static int condition(Object generator) throws ReflectiveOperationException {
        try { return (int)CONDITION.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** What the generator burns an hour: its consumption times the sandbox's fuel rate. */
    static float perHour(Object generator) throws ReflectiveOperationException {
        try { return (float)PER_HOUR.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** What the generator was set to burn ({@code totalPowerUsing}, the field). */
    static float using(Object generator) throws ReflectiveOperationException {
        try { return (float)USING.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static void setUsing(Object generator, float litres) throws ReflectiveOperationException {
        try { SET_USING.invokeExact(generator, litres); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static int lastHour(Object generator) throws ReflectiveOperationException {
        try { return (int)LAST_HOUR.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static void setLastHour(Object generator, int hour) throws ReflectiveOperationException {
        try { SET_LAST_HOUR.invokeExact(generator, hour); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static void setActivated(Object generator, boolean on) throws ReflectiveOperationException {
        try { SET_ACTIVATED.invokeExact(generator, on); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The generator on a loaded square, or null. */
    static Object generatorOf(Object square) throws ReflectiveOperationException {
        try { return (Object)GENERATOR_OF.invokeExact(square); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static float basePower() throws ReflectiveOperationException {
        try { return (float)BASE_POWER.invokeExact(); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /** The item type a generator was placed from, or null (for a game without the question). */
    static Object itemType(Object generator) throws ReflectiveOperationException {
        if (ITEM_TYPE == null) return null;
        try { return (Object)ITEM_TYPE.invokeExact(generator); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static boolean containerPowered(Object object, boolean flag) throws ReflectiveOperationException {
        try { return (boolean)CONTAINER_POWERED.invokeExact(object, flag); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static boolean switchPowered(Object object) throws ReflectiveOperationException {
        try { return (boolean)SWITCH_POWERED.invokeExact(object); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static boolean devicePowered(Object device) throws ReflectiveOperationException {
        try { return (boolean)DEVICE_POWERED.invokeExact(device); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static boolean squarePowered(Object square) throws ReflectiveOperationException {
        try { return (boolean)SQUARE_POWERED.invokeExact(square); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static Object containerSquare(Object container) throws ReflectiveOperationException {
        try { return (Object)CONTAINER_SQUARE.invokeExact(container); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static boolean battery(Object device) throws ReflectiveOperationException {
        try { return (boolean)BATTERY.invokeExact(device); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static Object deviceParent(Object device) throws ReflectiveOperationException {
        try { return (Object)DEVICE_PARENT.invokeExact(device); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    static Object containerParent(Object container) throws ReflectiveOperationException {
        try { return (Object)CONTAINER_PARENT.invokeExact(container); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }
}
