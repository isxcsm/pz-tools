package pzext.api;

/** Reads a Lua call's arguments. A wrong one is the calling mod's error, named in the message it gets. */
final class Arguments {
    /** What a name a mod gives (its handle's, a network's, a source's) must be. */
    static final String NAME_RULE = "1 to 64 letters, digits, '_', '.' or '-'";

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

    /** Whether the value is a string of 1 to 64 of A-Z, a-z, 0-9, '_', '.' and '-' (looked at letter by letter: no matcher is made per call). */
    static boolean isName(Object value) {
        if (!(value instanceof String text) || text.isEmpty() || text.length() > 64) return false;
        for (int at = 0; at < text.length(); at++) {
            char letter = text.charAt(at);
            if (!(letter >= 'a' && letter <= 'z' || letter >= 'A' && letter <= 'Z' || letter >= '0' && letter <= '9' || letter == '_' || letter == '.' || letter == '-')) return false;
        }
        return true;
    }
}
