package pzext.boot;

import java.io.PrintStream;
import java.lang.instrument.Instrumentation;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Puts the extension API's hooks into the synthetic game as its classes load, as the boot layer does. It also keeps the lines the
 * boot layer prints when a hook does not fit a class ("no hook in ..."): in the synthetic game every hook fits, so a line is a gap in
 * the synthetic game (see {@link #unexpected}).
 */
public final class TestAgent {
    /** The "no hook in" lines printed so far, in the order printed (a deliberate case is caught before it gets here). */
    public static final List<String> unexpected = Collections.synchronizedList(new ArrayList<>());

    private TestAgent() { }

    public static void premain(String arguments, Instrumentation instrumentation) {
        System.setErr(new PrintStream(System.err, true) {
            @Override public void println(String line) {
                if (line != null && line.startsWith("[PZExt] no hook in ")) unexpected.add(line);
                super.println(line);
            }
        });
        Hooks.install(instrumentation);
    }
}
