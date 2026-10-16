package pzext.api;

import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.LuaCallFrame;
import zombie.Lua.LuaManager;

/**
 * What a call into one of the API's Lua functions costs the API itself (Kahlua.function): reading the arguments, running
 * the body, pushing the results. Also that the function behaves as a Lua function does: its results are in order, nil is
 * pushed as nil, a body's own runtime error reaches Lua as it is, any other becomes one that names the API, and its text is
 * its name.
 */
final class KahluaCostTest {
    private KahluaCostTest() { }

    static void run() throws Exception {
        var lua = new Kahlua(LuaManager.class);
        Object function = lua.function("PZExtAPI.test.cost", arguments -> new Object[] { arguments[0], null, arguments[2], true });
        check(function.toString().equals("PZExtAPI.test.cost"), "A function's text is not its name: " + function);
        var java = (JavaFunction)function;
        var frame = new LuaCallFrame(1.0, "two", 3.0);
        int pushed = java.call(frame, 3);
        check(pushed == 4 && frame.results.size() == 4 && frame.results.get(0).equals(1.0) && frame.results.get(1) == null
            && frame.results.get(2).equals(3.0) && frame.results.get(3).equals(true), "A function's results were not pushed in order: " + frame.results);
        Object failing = lua.function("PZExtAPI.test.fails", arguments -> { throw new IllegalArgumentException("a bad argument"); });
        try { ((JavaFunction)failing).call(new LuaCallFrame(), 0); throw new AssertionError("An error of the body did not reach Lua"); }
        catch (IllegalArgumentException expected) { check("a bad argument".equals(expected.getMessage()), "The body's own message was changed"); }
        Object checked = lua.function("PZExtAPI.test.checked", arguments -> { throw new Exception("not a runtime error"); });
        try { ((JavaFunction)checked).call(new LuaCallFrame(), 0); throw new AssertionError("A checked error of the body did not reach Lua"); }
        catch (IllegalStateException expected) { check(expected.getMessage().startsWith("PZExtAPI: ") && expected.getMessage().contains("not a runtime error"), "Wrong text: " + expected.getMessage()); }
        Object other = lua.function("PZExtAPI.test.other", arguments -> new Object[0]);
        check(!other.equals(function) && other.hashCode() == System.identityHashCode(other), "Functions are not told apart by identity");

        var argumentsFrame = new LuaCallFrame(1.0, "two", 3.0);
        int rounds = 2_000_000;
        double best = Double.MAX_VALUE;
        long bytes = 0;
        for (int round = 0; round < 7; round++) {
            argumentsFrame.results.clear();
            long before = Allocations.allocated();
            long start = System.nanoTime();
            for (int index = 0; index < rounds; index++) {
                if ((index & 1023) == 0) argumentsFrame.results.clear();
                java.call(argumentsFrame, 3);
            }
            double each = (System.nanoTime() - start) / (double)rounds;
            if (each < best) { best = each; bytes = (Allocations.allocated() - before) / rounds; }
        }
        System.out.printf("kahlua: a call of a Lua function with 3 arguments and 4 results costs %.1f ns (best of 7 rounds of %,d), %d bytes a call%n",
            best, rounds, bytes);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
