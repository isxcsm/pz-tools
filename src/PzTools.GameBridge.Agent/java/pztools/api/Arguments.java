package pztools.api;

import java.util.regex.Pattern;

/** Reads a Lua call's arguments. A wrong one is the calling mod's error, named in the message it gets. */
final class Arguments {
    /** What a name a mod gives (its handle's, a network's, a source's) must be. */
    static final String NAME_RULE = "1 to 64 letters, digits, '_', '.' or '-'";
    private static final Pattern NAME = Pattern.compile("[A-Za-z0-9_.-]{1,64}");

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

    /** A name a mod gives: see {@link #NAME_RULE}. */
    static String name(Object[] arguments, int index, String call, String name) {
        String text = string(arguments, index, call, name);
        if (!isName(text)) throw new IllegalArgumentException(call + ": " + name + " must be " + NAME_RULE);
        return text;
    }

    static boolean isName(Object value) { return value instanceof String text && NAME.matcher(text).matches(); }
}
