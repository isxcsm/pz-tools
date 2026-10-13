package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;

/**
 * The numbers an object's mod data ({@code IsoObject.getModData()}, a Kahlua table) holds under the keys mods declare, read
 * for the points that name such keys ({@code machine.loadKey}, {@code anim.stepKey}). An object without mod data is not
 * given a table ({@code hasModData} is asked first). Allocates nothing.
 */
final class ObjectData {
    // IsoObject.hasModData(), getModData(); KahluaTable.rawget(Object).
    private final MethodHandle hasData, dataOf, rawget;

    ObjectData(ClassLoader loader, Class<?> object) throws ReflectiveOperationException {
        Class<?> table = Game.type(loader, "se.krka.kahlua.vm.KahluaTable");
        hasData = Game.exact(object.getMethod("hasModData"), MethodType.methodType(boolean.class, Object.class));
        dataOf = Game.exact(object.getMethod("getModData"), MethodType.methodType(Object.class, Object.class));
        rawget = Game.exact(table.getMethod("rawget", Object.class), MethodType.methodType(Object.class, Object.class, Object.class));
    }

    /**
     * The numbers held under the keys, multiplied, each held from 0 to {@code max} (a string, a NaN or no value is left out):
     * 1 for none, and for an object without mod data.
     */
    double product(String[] keys, Object object, double max) throws Throwable {
        if (keys.length == 0 || !(boolean)hasData.invokeExact(object)) return 1;
        Object table = (Object)dataOf.invokeExact(object);
        double product = 1;
        for (String key : keys)
            if ((Object)rawget.invokeExact(table, (Object)key) instanceof Number value && !Double.isNaN(value.doubleValue()))
                product *= Math.max(0, Math.min(max, value.doubleValue()));
        return product;
    }

    /** Whether a number other than 0 (and not a NaN) is held under one of the keys; false for an object without mod data. */
    boolean holds(String[] keys, Object object) throws Throwable {
        if (keys.length == 0 || !(boolean)hasData.invokeExact(object)) return false;
        Object table = (Object)dataOf.invokeExact(object);
        for (String key : keys)
            if ((Object)rawget.invokeExact(table, (Object)key) instanceof Number value && value.doubleValue() != 0 && !Double.isNaN(value.doubleValue()))
                return true;
        return false;
    }
}
