package pztools.bridge.runtime.api;

/** Reads a Lua call's arguments. A wrong one is the calling mod's error, named in the message it gets. */
final class Arguments {
    private Arguments() { }

    static int integer(Object[] arguments, int index, String call, String name) {
        return integer(arguments, index, call, name, Integer.MIN_VALUE, Integer.MAX_VALUE);
    }

    static int integer(Object[] arguments, int index, String call, String name, int min, int max) {
        Object value = index < arguments.length ? arguments[index] : null;
        if (!(value instanceof Number number) || number.doubleValue() != Math.rint(number.doubleValue())
                || number.doubleValue() < min || number.doubleValue() > max)
            throw new IllegalArgumentException(call + ": " + name + " must be a whole number"
                + (min == Integer.MIN_VALUE ? "" : " from " + min + " to " + max));
        return (int)number.doubleValue();
    }

    static double number(Object[] arguments, int index, String call, String name, double min, double max) {
        Object value = index < arguments.length ? arguments[index] : null;
        if (!(value instanceof Number number) || !(number.doubleValue() >= min && number.doubleValue() <= max))
            throw new IllegalArgumentException(call + ": " + name + " must be a number from " + min + " to " + max);
        return number.doubleValue();
    }

    static String string(Object[] arguments, int index, String call, String name) {
        Object value = index < arguments.length ? arguments[index] : null;
        if (!(value instanceof String text)) throw new IllegalArgumentException(call + ": " + name + " must be a string");
        return text;
    }
}
