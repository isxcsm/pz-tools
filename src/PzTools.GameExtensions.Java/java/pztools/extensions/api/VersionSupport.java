package pztools.extensions.api;

import java.util.regex.Pattern;

/** Inclusive version components; independent from bytecode/ABI safety checks. */
public record VersionSupport(String scope, String minimum, String maximum) {
    private static final Pattern VERSION = Pattern.compile("([0-9]{1,4})\\.([0-9]{1,4})(?:\\.[0-9]{1,4})?(?:[-+][A-Za-z0-9.-]+)?");
    public VersionSupport {
        if (!scope.equals("All") && !scope.equals("Major") && !scope.equals("Minor")) throw new IllegalArgumentException("Unknown version scope");
        if (scope.equals("All")) {
            if (minimum != null || maximum != null) throw new IllegalArgumentException("All has no bounds");
        } else if (minimum == null || maximum != null && bound(scope, maximum) < bound(scope, minimum))
            throw new IllegalArgumentException("Invalid version bounds");
        if (!scope.equals("All")) bound(scope, minimum);
    }
    public boolean matches(String installed) {
        if (scope.equals("All")) return true;
        if (installed == null || installed.length() > 80) return false;
        var match = VERSION.matcher(installed);
        if (!match.matches()) return false;
        long value = Long.parseLong(match.group(1));
        if (scope.equals("Minor")) value = value * 10000 + Long.parseLong(match.group(2));
        return value >= bound(scope, minimum) && (maximum == null || value <= bound(scope, maximum));
    }
    private static long bound(String scope, String value) {
        if (value == null || !value.matches(scope.equals("Major") ? "[0-9]{1,4}" : "[0-9]{1,4}\\.[0-9]{1,4}"))
            throw new IllegalArgumentException("Invalid version bound");
        String[] parts = value.split("\\.");
        return scope.equals("Major") ? Long.parseLong(parts[0]) : Long.parseLong(parts[0])*10000 + Long.parseLong(parts[1]);
    }
}