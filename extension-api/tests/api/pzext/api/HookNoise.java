package pzext.api;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;

/**
 * The boot layer says "no hook in ..." on the error stream when a hook does not fit a class. In the synthetic game every hook
 * fits (pzext.boot.TestAgent keeps the lines that say otherwise, and GameApiTest fails on them); a test that changes a class on
 * purpose, to see what the API does without a hook, says which lines it means to cause.
 */
final class HookNoise {
    private HookNoise() { }

    @FunctionalInterface interface Action<T> { T run() throws Exception; }

    /**
     * Runs {@code action}, which must print exactly the "no hook in" line of each of {@code labels} (a hook's label, such as
     * {@code Helicopter.writes:flight}; one that is printed twice twice), and nothing of that kind besides. What else it prints goes on.
     */
    static <T> T expecting(Action<T> action, String... labels) throws Exception {
        PrintStream real = System.err;
        var caught = new ByteArrayOutputStream();
        T result;
        System.setErr(new PrintStream(caught, true, StandardCharsets.UTF_8));
        try { result = action.run(); }
        finally { System.setErr(real); }
        var pending = new java.util.ArrayList<>(java.util.List.of(labels));
        for (String line : caught.toString(StandardCharsets.UTF_8).split("\\R")) {
            if (line.isEmpty()) continue;
            String prefix = "[PZExt] no hook in ";
            if (!line.startsWith(prefix)) { real.println(line); continue; }
            String rest = line.substring(prefix.length());
            String label = pending.stream().filter(candidate -> rest.startsWith(candidate + ": ")).findFirst().orElse(null);
            if (label == null) throw new AssertionError("A hook was missing that the test did not mean: " + line);
            pending.remove(label);
        }
        if (!pending.isEmpty()) throw new AssertionError("The hooks were not missing: " + pending);
        return result;
    }
}
