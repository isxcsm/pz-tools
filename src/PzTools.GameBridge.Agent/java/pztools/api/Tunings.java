package pztools.api;

import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The numbers the formulas work with that can be changed while the game runs (PZToolsAPI.formulas.tune), so that they
 * are tuned in the game rather than by a build. One value for the game, not declared by a mod and not saved: a game
 * starts with the defaults. A formula keeps its tunings and reads each as it works (a volatile field, no lookup).
 */
final class Tunings {
    /** One number: its name, what it is, its default and its range; read by the formula with {@link #value}. */
    static final class Tuning {
        final String name, about;
        final float initial, min, max;
        private volatile float value;

        private Tuning(String name, float initial, float min, float max, String about) {
            this.name = name;
            this.about = about;
            this.initial = initial;
            this.min = min;
            this.max = max;
            value = initial;
        }

        float value() { return value; }

        /** The value as a whole number (a count of squares). */
        int whole() { return Math.round(value); }

        void set(float next) {
            if (!(next >= min && next <= max)) throw new IllegalArgumentException(name + " must be a number from " + min + " to " + max);
            value = next;
        }

        void reset() { value = initial; }
    }

    private final Map<String, Tuning> byName = new LinkedHashMap<>();

    Tuning add(String name, float initial, float min, float max, String about) {
        var tuning = new Tuning(name, initial, min, max, about);
        if (byName.putIfAbsent(name, tuning) != null) throw new IllegalStateException("two tunings named " + name);
        return tuning;
    }

    /** The tuning of the name, or null. */
    Tuning find(String name) { return byName.get(name); }

    Collection<Tuning> all() { return Collections.unmodifiableCollection(byName.values()); }
}
