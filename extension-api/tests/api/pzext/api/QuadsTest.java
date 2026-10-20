package pzext.api;

import java.util.List;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.core.SpriteRenderer;
import zombie.core.textures.Texture;
import zombie.ui.UIElement;

/**
 * {@code draw.rects} and {@code draw.quads}: many shapes from a flat array of numbers, drawn as the game draws them from a window
 * (placed by the window's place and scroll, asked once for the call), the numbers checked before anything is drawn, the count
 * given or the whole list, and what a call costs beside the stub's own recording. {@code draw.keep}, {@code draw.clear} and
 * {@code draw.play}: a window's own draws kept on the tape of a Lua table and played in order, from a start and for a count.
 */
final class QuadsTest {
    private QuadsTest() { }

    static void run(KahluaTable api) throws Exception {
        var draw = (KahluaTable)api.rawget("draw");
        check(draw != null && draw.rawget("rects") != null && draw.rawget("quads") != null && draw.rawget("keep") != null && draw.rawget("play") != null && draw.rawget("clear") != null, "PZExtAPI.draw is missing");
        var window = new UIElement();
        window.parent = new UIElement();
        window.parent.x = 10;
        window.parent.y = 20;
        window.x = 100;
        window.y = 50;
        window.xScroll = 5.0;
        window.yScroll = -3.0;
        rects(draw, window);
        quads(draw, window);
        tapes(draw, window);
        rejects(draw, window);
        cost(draw, window);
    }

    private static KahluaTable list(double... values) {
        var table = LuaManager.platform.newTable();
        for (int index = 0; index < values.length; index++) table.rawset((double)(index + 1), values[index]);
        return table;
    }

    private static List<Object[]> rects() { return SpriteRenderer.rects; }

    private static void keep(KahluaTable draw, KahluaTable tape, Object kind, Object picture, double... eight) {
        var arguments = new Object[3 + eight.length];
        arguments[0] = tape;
        arguments[1] = kind;
        arguments[2] = picture;
        for (int index = 0; index < eight.length; index++) arguments[3 + index] = eight[index];
        FormulasTest.call(draw, "keep", arguments);
    }

    private static void tapes(KahluaTable draw, UIElement window) {
        var picture = new Texture("test", 8, 8);
        var grain = new Texture("grain", 4, 4);
        var tape = LuaManager.platform.newTable();
        // A table never kept: false, nothing drawn.
        window.draws.clear();
        check(Boolean.FALSE.equals(FormulasTest.call(draw, "play", window, tape).get(0)), "A table with no tape was played");
        keep(draw, tape, 1.0, false, 1, 2, 3, 4, 0.1, 0.2, 0.3, 0.4);
        keep(draw, tape, 2.0, grain, 0, 0, 50, 60, 1, 1, 1, 0.5);
        keep(draw, tape, 3.0, picture, 5, 6, 7, 8, 1, 1, 1, 1);
        check(Double.valueOf(3).equals(FormulasTest.call(draw, "play", window, tape).get(0)), "The tape's count was not given");
        check(window.draws.size() == 3, "Three draws were not drawn: " + window.draws.size());
        Object[] first = window.draws.get(0), second = window.draws.get(1), third = window.draws.get(2);
        check(first[0].equals("scaled") && first[1] == null && first[2].equals(1.0) && first[5].equals(4.0) && first[9].equals(0.4),
            "A rectangle: " + java.util.Arrays.toString(first));
        check(second[0].equals("tiled") && second[1] == grain && second[4].equals(50.0) && second[9].equals(0.5), "Tiled: " + java.util.Arrays.toString(second));
        check(third[0].equals("aspect") && third[1] == picture && third[2].equals(5.0), "Its aspect kept: " + java.util.Arrays.toString(third));
        // From a start, for a count; a Lua window is its javaObject.
        window.draws.clear();
        var lua = LuaManager.platform.newTable();
        lua.rawset("javaObject", window);
        FormulasTest.call(draw, "play", lua, tape, 1.0, 2.0);
        check(window.draws.size() == 1 && window.draws.get(0)[0].equals("tiled"), "The start and count were not used: " + window.draws.size());
        FormulasTest.call(draw, "play", window, tape, null, 3.0);
        check(window.draws.size() == 2 && window.draws.get(1)[0].equals("aspect"), "From a start to the end");
        FormulasTest.call(draw, "play", window, tape, 0.0);
        check(window.draws.size() == 2, "None drawn as something");
        // Hidden: nothing.
        window.visible = false;
        FormulasTest.call(draw, "play", window, tape);
        check(window.draws.size() == 2, "A hidden window was drawn in");
        window.visible = true;
        // Cleared: empty, kept again from the start; a tape grows past its first arrays.
        FormulasTest.call(draw, "clear", tape);
        check(Double.valueOf(0).equals(FormulasTest.call(draw, "play", window, tape).get(0)), "A cleared tape still held draws");
        for (int n = 0; n < 100; n++) keep(draw, tape, 1.0, false, n, 0, 1, 1, 1, 1, 1, 1);
        window.draws.clear();
        FormulasTest.call(draw, "play", window, tape, 1.0, 100.0);
        check(window.draws.size() == 1 && window.draws.get(0)[2].equals(99.0), "The hundredth draw: " + window.draws.size());
        rejects(draw, "keep", "tape must be a table", 5.0, 1.0, false, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
        rejects(draw, "keep", "kind must be 1, 2 or 3", tape, 4.0, false, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
        rejects(draw, "keep", "picture must be a texture or false", tape, 1.0, "x", 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
        rejects(draw, "keep", "picture must be a texture", tape, 2.0, false, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
        rejects(draw, "keep", "w must be a number", tape, 1.0, false, 0.0, 0.0, Double.NaN, 1.0, 1.0, 1.0, 1.0, 1.0);
        rejects(draw, "keep", "a must be a number", tape, 1.0, false, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0);
        rejects(draw, "play", "tape must be a table", window, 5.0);
        rejects(draw, "play", "count is 200 but the tape holds only 100 draws from draw 1", window, tape, 200.0);
        rejects(draw, "play", "start must be a whole number", window, tape, 1.0, 0.0);
        check(Double.valueOf(100).equals(FormulasTest.call(draw, "play", window, tape, 0.0).get(0)), "A refused keep changed the tape");
    }

    private static void rects(KahluaTable draw, UIElement window) {
        // A window is at (110, 70) with its parent's place; scrolled 5 across and -3 down (the game scrolls the rows, not the columns' top).
        rects().clear();
        FormulasTest.call(draw, "rects", window, list(1, 2, 30, 40, 0.1, 0.2, 0.3, 0.4, 7.9, 8.9, 3.9, 2.9, 1, 0, 0, 1));
        check(rects().size() == 2, "Two rectangles were not drawn: " + rects().size());
        Object[] first = rects().get(0), second = rects().get(1);
        check(first[0] == null && first[1].equals(116) && first[2].equals(69) && first[3].equals(30) && first[4].equals(40)
            && first[5].equals(0.1f) && first[6].equals(0.2f) && first[7].equals(0.3f) && first[8].equals(0.4f), "The first rectangle: " + java.util.Arrays.toString(first));
        check(second[1].equals(122) && second[2].equals(75) && second[3].equals(3) && second[4].equals(2) && second[5].equals(1f) && second[8].equals(1f),
            "Pixels are whole numbers, cut: " + java.util.Arrays.toString(second));
        // A Lua window is its javaObject.
        rects().clear();
        var lua = LuaManager.platform.newTable();
        lua.rawset("javaObject", window);
        FormulasTest.call(draw, "rects", lua, list(0, 0, 1, 1, 1, 1, 1, 1));
        check(rects().size() == 1 && rects().get(0)[1].equals(115) && rects().get(0)[2].equals(67), "A Lua window was not drawn in: " + rects().size());
        // The count: fewer than the list holds; none; more is an error; a part of a shape does not count.
        rects().clear();
        double[] four = new double[32];
        for (int index = 0; index < 4; index++) { four[index * 8 + 2] = 1; four[index * 8 + 3] = 1; }
        FormulasTest.call(draw, "rects", window, list(four), 3.0);
        check(rects().size() == 3, "The count was not used: " + rects().size());
        rects().clear();
        FormulasTest.call(draw, "rects", window, list(four), 0.0);
        FormulasTest.call(draw, "rects", window, list());
        check(rects().isEmpty(), "Nothing was drawn as something");
        FormulasTest.call(draw, "rects", window, list(0, 0, 1, 1, 1, 1, 1, 1, 9, 9, 9));
        check(rects().size() == 1, "Three numbers over a shape drew another: " + rects().size());
        // Hidden: nothing, with the numbers still checked.
        rects().clear();
        window.visible = false;
        FormulasTest.call(draw, "rects", window, list(four));
        check(rects().isEmpty(), "A hidden window was drawn in");
        rejects(draw, "rects", "list[1] must be a number", window, list(Double.NaN, 0, 1, 1, 1, 1, 1, 1));
        window.visible = true;
        // Off the screen above or far below: not drawn, as the game's own rectangles are not.
        rects().clear();
        FormulasTest.call(draw, "rects", window, list(0, -200, 10, 10, 1, 1, 1, 1, 0, 5000, 10, 10, 1, 1, 1, 1, 0, -60, 10, 10, 1, 1, 1, 1, 0, 4000, 10, 10, 1, 1, 1, 1));
        check(rects().size() == 2 && rects().get(0)[2].equals(7) && rects().get(1)[2].equals(4067), "Off the screen: " + rects().size());
        // The place is asked once for the call, however many the shapes.
        window.placeAsks = 0;
        FormulasTest.call(draw, "rects", window, list(four));
        int one = window.placeAsks;
        window.placeAsks = 0;
        FormulasTest.call(draw, "rects", window, list(new double[8 * 500]), 500.0);
        check(window.placeAsks == one && one > 0, "The place was asked " + window.placeAsks + " times for 500 rectangles, " + one + " for 4");
    }

    private static void quads(KahluaTable draw, UIElement window) {
        var texture = new Texture("test", 8, 8);
        window.quads.clear();
        FormulasTest.call(draw, "quads", window, texture, list(1, 2, 3, 4, 5, 6, 7, 8, 0.1, 0.2, 0.3, 0.4, 11, 12, 13, 14, 15, 16, 17, 18, 1, 1, 1, 1));
        check(window.quads.size() == 2, "Two quads were not drawn: " + window.quads.size());
        Object[] first = window.quads.get(0);
        check(first[0] == texture && first[1].equals(1.0) && first[8].equals(8.0) && first[9].equals(0.1) && first[12].equals(0.4), "The first quad: " + java.util.Arrays.toString(first));
        check(window.quads.get(1)[1].equals(11.0) && window.quads.get(1)[12].equals(1.0), "The second quad");
        window.quads.clear();
        FormulasTest.call(draw, "quads", window, texture, list(new double[36]), 2.0);
        check(window.quads.size() == 2, "The count of quads was not used");
        FormulasTest.call(draw, "quads", window, texture, list());
        check(window.quads.size() == 2, "Nothing was drawn as something");
        // Drawn in a Lua window as well, with nothing placed by the call: the corners are the screen's.
        var lua = LuaManager.platform.newTable();
        lua.rawset("javaObject", window);
        FormulasTest.call(draw, "quads", lua, texture, list(new double[12]));
        check(window.quads.size() == 3, "A Lua window was not drawn in");
    }

    private static void rejects(KahluaTable draw, UIElement window) {
        var texture = new Texture("test", 8, 8);
        rejects(draw, "rects", "element must be a window of the game's interface", 5.0, list(0, 0, 1, 1, 1, 1, 1, 1));
        rejects(draw, "rects", "element must be a window of the game's interface", LuaManager.platform.newTable(), list());
        rejects(draw, "rects", "element must be a window of the game's interface", null, list());
        rejects(draw, "rects", "list must be a table of numbers", window, "x");
        rejects(draw, "rects", "list must be a table of numbers", window, null);
        rejects(draw, "rects", "count is 2 but the list holds only 1 shapes of 8 numbers", window, list(0, 0, 1, 1, 1, 1, 1, 1), 2.0);
        rejects(draw, "rects", "count must be a whole number from 0 to 16384", window, list(), 16385.0);
        rejects(draw, "rects", "count must be a whole number from 0 to 16384", window, list(), 1.5);
        rejects(draw, "rects", "list[3] must be a number", window, list(0, 0, Double.POSITIVE_INFINITY, 1, 1, 1, 1, 1));
        rejects(draw, "quads", "texture must be a texture", window, "x", list(new double[12]));
        rejects(draw, "quads", "texture must be a texture", window, null, list(new double[12]));
        rejects(draw, "quads", "list must be a table of numbers", window, texture, 5.0);
        rejects(draw, "quads", "count is 2 but the list holds only 1 shapes of 12 numbers", window, texture, list(new double[12]), 2.0);
        // A bad number draws nothing, not the shapes before it.
        SpriteRenderer.rects.clear();
        var bad = LuaManager.platform.newTable();
        for (int index = 1; index <= 16; index++) bad.rawset((double)index, index == 12 ? "x" : 1.0);
        rejects(draw, "rects", "list[12] must be a number", window, bad);
        check(SpriteRenderer.rects.isEmpty(), "A list with a bad number drew the shapes before it");
        window.quads.clear();
        var badQuads = LuaManager.platform.newTable();
        for (int index = 1; index <= 24; index++) badQuads.rawset((double)index, index == 20 ? true : 1.0);
        rejects(draw, "quads", "list[20] must be a number", window, texture, badQuads);
        check(window.quads.isEmpty(), "A list with a bad number drew the quads before it");
    }

    private static void rejects(KahluaTable draw, String name, String message, Object... arguments) {
        try { FormulasTest.call(draw, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.draw." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    /** A call of 1000 rectangles against 1000 calls of the stub's own: the stub records each, so the difference is the API's. */
    private static void cost(KahluaTable draw, UIElement window) {
        var numbers = new double[8 * 1000];
        for (int shape = 0; shape < 1000; shape++) { numbers[shape * 8] = shape % 100; numbers[shape * 8 + 1] = shape / 100 * 10; numbers[shape * 8 + 2] = 4; numbers[shape * 8 + 3] = 4; for (int c = 4; c < 8; c++) numbers[shape * 8 + c] = 0.5; }
        var shapes = list(numbers);
        Object rects = draw.rawget("rects");
        var arguments = new Object[] { window, shapes };
        var sprites = SpriteRenderer.instance;
        for (int warm = 0; warm < 300; warm++) { SpriteRenderer.rects.clear(); FormulasTest.invoke(rects, arguments); }
        int rounds = 2000;
        SpriteRenderer.rects.clear();
        long bytes = allocated(), start = System.nanoTime();
        for (int n = 0; n < rounds; n++) { FormulasTest.invoke(rects, arguments); SpriteRenderer.rects.clear(); }
        long time = System.nanoTime() - start;
        bytes = allocated() - bytes;
        SpriteRenderer.rects.clear();
        long base = allocated(), baseStart = System.nanoTime();
        for (int n = 0; n < rounds; n++) { for (int shape = 0; shape < 1000; shape++) sprites.renderi(null, 5, 5, 4, 4, 0.5f, 0.5f, 0.5f, 0.5f, null); SpriteRenderer.rects.clear(); }
        long baseTime = System.nanoTime() - baseStart;
        base = allocated() - base;
        window.visible = false;
        long hidden = allocated();
        for (int n = 0; n < rounds; n++) FormulasTest.invoke(rects, arguments);
        hidden = allocated() - hidden;
        window.visible = true;
        System.out.printf("draw.rects: reading 1000 rectangles (a hidden window) allocates %d bytes%n", hidden / rounds);
        System.out.printf("draw.rects: 1000 rectangles cost %.1f us (the synthetic table reads by hash), %d bytes; the stub alone %.1f us, %d bytes%n",
            time / 1000.0 / rounds, bytes / rounds, baseTime / 1000.0 / rounds, base / rounds);
        check(bytes <= base + base / 4, "The call allocated " + bytes / rounds + " bytes a call, the stub alone " + base / rounds);
        SpriteRenderer.rects.clear();
    }

    private static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
