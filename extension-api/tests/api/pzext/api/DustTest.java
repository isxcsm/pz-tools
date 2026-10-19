package pzext.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL20;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.core.SpriteRenderer;
import zombie.core.opengl.RenderThread;
import zombie.core.textures.Texture;
import zombie.core.textures.TextureFBO;
import zombie.ui.TextManager;
import zombie.ui.UIFont;
import zombie.ui.UIManager;

/**
 * The burn's pieces (Dust) against the synthetic game: its schedule (each cell's start, life, drift and alpha) and its cells cut
 * from a picture, as pure arithmetic; a fade instead without the game's frame buffers or the drawing of the pictures; wrong fields
 * and leave names; a newer API takes the burn's fields over and lets the older one's pictures go. The burn drawn is LooksTest's.
 */
final class DustTest {
    private static final double SECOND = 1e9;
    private static final long[] NOW = { 5_000_000_000_000L };
    // The program's "mode" uniform, as the synthetic GL records it.
    private static final int MODE = 900;

    private DustTest() { }

    static void run(KahluaTable api, KahluaTable text, Object mod) throws Exception {
        schedule();
        cells();
        useClock();
        try {
            fallback(text, mod);
            rejects(text, mod);
            takeover(api, text, mod);
            System.out.println("PASS: dust: the schedule and cells are as computed; a burn fades where its picture cannot be made; wrong fields and leaves are errors; a newer API takes the fields over");
        } finally {
            GL11.ink = null;
            GL20.uniforms.remove("mode");
            TextureFBO.supported = true;
            TextManager.record = true;
            SpriteRenderer.flush();
            RenderThread.flush();
        }
    }

    private static void useClock() { GameApi.texts().clock = () -> NOW[0]; GameApi.texts().frameMost = Long.MAX_VALUE; }

    private static void advance(double seconds) { NOW[0] += Math.round(seconds * SECOND); }

    // ---- the schedule ----

    /** The schedule is arithmetic on a seed: bounded, ordered along the sweep, the same twice, whole before a cell starts and gone at its end. */
    private static void schedule() {
        check(near(Dust.cell(108, 1), 4.32) && Dust.cell(30, 1) == Dust.MIN_CELL && near(Dust.cell(76.5, 2), 6.12), "A cell's side is wrong");
        double total = Dust.SWEEP + Dust.JITTER + Dust.LIFE;
        check(near(total, 1), "The sweep, its jitter and a cell's life do not fill the leave: " + total);
        for (long seed : new long[] { 1, 42, -7, 0x5DEECE66DL })
            for (int index = 0; index < 400; index++) {
                double along = (index % 20) / 19.0, across = (index / 20) / 19.0;
                double start = Dust.start(along, across, seed, index), life = Dust.life(seed, index);
                check(start >= 0 && start <= Dust.SWEEP + Dust.JITTER + 1e-12, "A cell starts at " + start);
                check(life >= 0.75 * Dust.LIFE - 1e-12 && life <= Dust.LIFE + 1e-12 && start + life <= 1 + 1e-12, "A cell outlives the leave: " + start + " + " + life);
                check(start == Dust.start(along, across, seed, index), "The schedule is not the same twice");
                // Further along the sweep, later by the sweep's share alone.
                check(near(Dust.start(1, across, seed, index) - Dust.start(0, across, seed, index), Dust.SWEEP), "The start does not follow the sweep");
                double wave = Dust.wave(across, seed);
                check(wave >= 0 && wave <= 1 && Math.abs(Dust.wave(across + 1e-4, seed) - wave) < 1e-2, "The front's wave is not smooth: " + wave);
            }
        check(Dust.start(0.5, 0.5, 1, 3) != Dust.start(0.5, 0.5, 2, 3), "Another seed gives the same schedule");
        // The noise is clumpy: in 0 to 1, near cells alike, far ones not.
        double lowest = 1, highest = 0, step = 0;
        for (int column = 0; column < 60; column++)
            for (int row = 0; row < 20; row++) {
                double here = Dust.grain(column, row, 5);
                lowest = Math.min(lowest, here);
                highest = Math.max(highest, here);
                step = Math.max(step, Math.abs(Dust.grain(column + 1, row, 5) - here));
            }
        check(lowest >= 0 && highest <= 1 && highest - lowest > 0.4 && step < 0.35, "The noise is not clumpy: " + lowest + " to " + highest + ", steps of " + step);
        check(Dust.caught(Dust.CATCH) == 0 && Dust.caught(1) == 1 && Dust.driftX(Dust.CATCH, 1, 1, 0.3) == 0 && Dust.driftY(Dust.CATCH, 1, 1, 0.3) > 0,
            "A flake does not sag before the wind catches it");
        check(Dust.alpha(-1) == 1 && Dust.alpha(0) == 1 && near(Dust.alpha(Dust.HOLD), 1) && near(Dust.alpha((1 + Dust.HOLD) / 2), 0.5) && Dust.alpha(1) == 0 && Dust.alpha(2) == 0, "A cell's alpha is wrong");
        for (double age = 0; age < 1; age += 0.05) check(Dust.alpha(age + 0.05) <= Dust.alpha(age), "A cell's alpha rises at " + age);
        check(Dust.ease(0) == 0 && Dust.ease(1) == 1 && near(Dust.ease(0.5), 0.3125), "A cell's ease is wrong");
        // A spark leaving is hot, and has cooled by COOL of its life.
        check(Dust.heat(0) == 1 && Dust.heat(Dust.COOL) == 0 && Dust.heat(1) == 0 && Dust.heat(Dust.COOL / 2) > 0 && Dust.heat(Dust.COOL / 2) < 1, "A spark does not cool");
        for (double age = 0; age < 1; age += 0.05) check(Dust.ease(age + 0.05) > Dust.ease(age), "A flake turns back at " + age);
        for (double turns = -2; turns < 2; turns += 0.01)
            check(Math.abs(Dust.wobble(turns) - Math.sin(2 * Math.PI * turns)) < 0.03, "The swirl's wave is not a sine's shape at " + turns);
        check(Dust.wobble(0) == 0 && Dust.wobble(0.25) == 1 && Dust.wobble(0.75) == -1, "The swirl's wave does not reach its peaks");
        for (double phase = 0; phase < 1; phase += 0.1) {
            check(Dust.driftX(0, 1, 1, phase) == 0 && Dust.driftY(0, 1, 1, phase) == 0, "A cell moved before it started");
            check(Dust.driftX(1, 1, 1.2, phase) > 3.5 && Dust.driftX(1, -1, 1.2, phase) < -3.5, "A cell does not go a long way to its side");
            check(Dust.driftY(1, 1, 1.2, phase) < -0.8 && Dust.driftY(1, 0.6, 1.2, phase) < -0.4, "A cell does not rise: " + Dust.driftY(1, 1, 1.2, phase));
        }
    }

    /** Cells of a picture: the ones with ink, by lanes in the sweep's order, larger cells over the most. */
    private static void cells() {
        // A block of ink 80 by 30 in a picture 100 by 40, with cells of 2: columns 5 to 44, rows 2 to 17.
        Dust.Alpha block = (x, y) -> x >= 10 && x < 90 && y >= 5 && y < 35 ? 255 : 0;
        Dust.Cells right = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.RIGHT, 9, Dust.MAX_CELLS);
        check(right.count == 640 && right.lanes == 20 && right.columns == 50 && right.rows == 20 && right.size == 2, "The cells are " + right.count);
        check(right.laneFrom[0] == 0 && right.laneFrom[2] == 0 && right.laneFrom[3] == 40 && right.laneFrom[20] == 640, "The lanes are wrong");
        for (int lane = 2; lane < 18; lane++) {
            int from = right.laneFrom[lane];
            check(right.row[from] == lane && right.column[from] == 5 && right.column[from + 39] == 44, "A lane is not in the sweep's order");
            for (int cell = from; cell < right.laneFrom[lane + 1]; cell++) {
                check(right.side[cell] > 0 && right.rise[cell] >= 0.5 && right.along(cell) == right.column[cell], "A cell to the right goes the other way");
                check(right.flake[cell] >= 0.4 && right.flake[cell] <= 1, "A flake's size is " + right.flake[cell]);
            }
        }
        var again = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.RIGHT, 9, Dust.MAX_CELLS);
        check(Arrays.equals(right.start, again.start) && Arrays.equals(right.rise, again.rise), "The same picture gives other cells");
        Dust.Cells left = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.LEFT, 9, Dust.MAX_CELLS);
        check(left.column[left.laneFrom[2]] == 44 && left.side[0] < 0 && left.along(left.laneFrom[2]) == 5, "A sweep to the left does not start at the right");
        Dust.Cells up = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.UP, 9, Dust.MAX_CELLS);
        check(up.lanes == 50 && up.row[up.laneFrom[5]] == 17 && up.count == 640, "A sweep up does not go by columns from the bottom");
        Dust.Cells down = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.DOWN, 9, Dust.MAX_CELLS);
        check(down.row[down.laneFrom[5]] == 2, "A sweep down does not start at the top");
        // From the top right corner: rows from the right; the corner first, a row lower later; the flakes go right, back to it.
        Dust.Cells corner = Dust.Cells.of(block, 100, 40, 2, Dust.Sweep.DOWNLEFT, 9, Dust.MAX_CELLS);
        int topRight = corner.laneFrom[2], belowIt = corner.laneFrom[17], topLeft = corner.laneFrom[3] - 1;
        check(corner.lanes == 20 && corner.column[topRight] == 44 && corner.row[belowIt] == 17 && corner.column[belowIt] == 44 && corner.column[topLeft] == 5
            && corner.along(topRight) == 5 + 2 && corner.side[topRight] > 0 && corner.side[belowIt] > 0,
            "A sweep from the top right corner does not go by rows from the right, or its flakes do not go back to the corner");
        // Along a row the cells are further from the corner; the top right starts within the sweep's first tenth (and its jitter),
        // the bottom left in its last.
        boolean across = true;
        for (int lane = 2; lane < 18; lane++) across &= corner.along(corner.laneFrom[lane] + 39) > corner.along(corner.laneFrom[lane]);
        int bottomLeft = corner.laneFrom[18] - 1;
        check(across && corner.column[bottomLeft] == 5 && corner.start[topRight] <= 0.1 * Dust.SWEEP + Dust.JITTER + 1e-6
            && corner.start[bottomLeft] >= 0.9 * Dust.SWEEP, "A sweep from the top right corner does not start there");
        // All ink, 300 by 300 at cells of 1: larger cells, at most the most.
        Dust.Cells full = Dust.Cells.of((x, y) -> 255, 300, 300, 1, Dust.Sweep.RIGHT, 1, 1000);
        check(full.count <= 1000 && full.count > 600 && full.size > 9, "A large picture has " + full.count + " cells of " + full.size);
        check(Dust.Cells.of((x, y) -> 0, 50, 50, 2, Dust.Sweep.RIGHT, 1, 100) == null, "A picture without ink has cells");
        check(Dust.Cells.of((x, y) -> Dust.INK - 1, 50, 50, 2, Dust.Sweep.RIGHT, 1, 100) == null, "A faint picture has cells");
    }

    // ---- the burn ----

    /** Without the game's frame buffers, or the drawing of the pictures, a burn fades as {@code "fade"} does. */
    private static void fallback(KahluaTable text, Object mod) {
        Texts texts = GameApi.texts();
        Dust.Gl gl = texts.dust;
        texts.dust = null;
        try {
            double key = show(text, mod, "text", "Plain", "hold", 0.0, "leave", "burn", "leaveTime", 1.0);
            render();
            advance(0.5);
            render();
            check(near(alpha(last("Plain")), 0.5) && quads().isEmpty(), "A burn without the game's frame buffers did not fade");
            FormulasTest.call(text, "hide", mod, key, true);
        } finally { texts.dust = gl; }
        // A game whose frame buffers are not supported: a fade too, and nothing made.
        Looks.Gl looks = texts.looks;
        GL20.uniforms.put("mode", MODE);
        texts.looks = Looks.Gl.open(DustTest.class.getClassLoader());
        TextureFBO.supported = false;
        try {
            int textures = Texture.made;
            double key = show(text, mod, "text", "Unsupported", "hold", 0.0, "leave", "burn", "leaveTime", 1.0);
            render();
            advance(0.5);
            render();
            check(near(alpha(last("Unsupported")), 0.5) && Texture.made == textures && RenderThread.queued.isEmpty(), "A burn without frame buffers did not fade");
            FormulasTest.call(text, "hide", mod, key, true);
        } finally {
            TextureFBO.supported = true;
            texts.looks = looks;
        }
    }

    /** Wrong burn fields are Lua errors; a title takes {@code leave} and the burn's fields of any style. */
    private static void rejects(KahluaTable text, Object mod) {
        rejects(text, "dustSize goes with spec.leave = \"burn\" or \"flare\"", "show", mod, table("text", "x", "dustSize", 2.0));
        rejects(text, "spec.dustSweep must be one of \"right\", \"left\", \"up\", \"down\"", "show", mod, table("text", "x", "leave", "burn", "dustSweep", "sideways"));
        rejects(text, "spec.dustSize must be a number from 0.25 to 8", "show", mod, table("text", "x", "leave", "burn", "dustSize", 9.0));
        rejects(text, "spec.dustDrift must be a number from 0 to 4", "show", mod, table("text", "x", "leave", "burn", "dustDrift", -1.0));
        rejects(text, "spec.dustDrift goes with leave = \"burn\" or \"flare\"", "title", mod, table("text", "x", "style", "stamp", "dustDrift", 2.0));
        rejects(text, "spec.dustBurn goes with leave = \"burn\" or \"flare\"", "title", mod, table("text", "x", "style", "stamp", "dustBurn", table("r", 1.0, "g", 0.3, "b", 0.1)));
        rejects(text, "spec.dustBurn must be a table", "show", mod, table("text", "x", "leave", "burn", "dustBurn", "red"));
        rejects(text, "spec.dustBurn must be a table", "show", mod, table("text", "x", "leave", "burn", "dustBurn", table("r", 2.0, "g", 0.3, "b", 0.1)));
        double burning = (Double)FormulasTest.call(text, "title", mod, table("text", "Burning", "style", "dust", "dustBurn", table("r", 0.9, "g", 0.3, "b", 0.1))).get(0);
        check((Boolean)FormulasTest.call(text, "shown", mod, burning).get(0), "A dust-style title did not take the burn");
        FormulasTest.call(text, "hide", mod, burning, true);
        rejects(text, "spec.leave must be one of", "title", mod, table("text", "x", "leave", "explode"));
        // The crumbling "dust" was a leave once: it is no leave now.
        rejects(text, "spec.leave must be one of", "title", mod, table("text", "x", "leave", "dust"));
        rejects(text, "spec.leave must be one of", "show", mod, table("text", "x", "leave", "dust"));
        double key = (Double)FormulasTest.call(text, "title", mod, table("text", "Stamped", "style", "stamp", "leave", "burn", "leaveTime", 2.0, "dustSweep", "up")).get(0);
        check((Boolean)FormulasTest.call(text, "shown", mod, key).get(0), "A stamp title did not take the burn");
        FormulasTest.call(text, "hide", mod, key, true);
        render();
        SpriteRenderer.flush();
        RenderThread.flush();
    }

    /** A newer API takes the burn's fields over, and lets go the older one's pictures from its own drawing. */
    private static void takeover(KahluaTable api, KahluaTable text, Object mod) throws Exception {
        GL11.ink = (x, y) -> 255;
        Texts texts = GameApi.texts();
        Looks.Gl looks = texts.looks;
        GL20.uniforms.put("mode", MODE);
        texts.looks = Looks.Gl.open(DustTest.class.getClassLoader());
        show(text, mod, "text", "Kept", "hold", 100.0, "leave", "burn", "leaveTime", 1.0, "dustSweep", "up", "dustSize", 1.5, "dustDrift", 0.5,
            "dustBurn", table("r", 1.0, "g", 0.5, "b", 0.25));
        Texture picture = prepare();
        texts.looks = looks;
        ClassLoader game = DustTest.class.getClassLoader();
        GameApi.frame(game);
        KahluaTable meta = api.getMetatable();
        String kept = (String)meta.rawget("texts");
        check(kept.contains("\t1.5\tUP\t0.5") && kept.contains("\t1.0,0.5,0.25,1.0"), "The burn's fields are not kept for a newer API: " + kept);
        GameApi.register(LuaManager.class);
        useClock();
        render();
        check(names().contains("generic") && last("Kept") != null, "The newer API did not let the older one's picture go, or does not show the text");
        SpriteRenderer.flush();
        check(picture.destroyed, "The older API's picture stayed");
        FormulasTest.call(mod, "clear");
        render();
        SpriteRenderer.flush();
        RenderThread.flush();
        GL11.ink = null;
    }

    // ---- helpers ----

    /** Makes, draws into and reads back the picture of the text just shown (a look's): the picture. */
    private static Texture prepare() {
        int textures = Texture.made;
        render();
        check(Texture.made == textures + 1, "No picture was made");
        RenderThread.flush();
        render();
        SpriteRenderer.flush();
        render();
        // The frame buffer last made is the text's.
        return (Texture)TextureFBO.last.getTexture();
    }

    /** The clock at {@code seconds} after {@code origin}. */
    private static void at(long origin, double seconds) { NOW[0] = origin + Math.round(seconds * SECOND); }

    /** The interface drawn, as the main thread does. */
    private static void render() {
        TextManager.calls.clear();
        UIManager.render();
    }

    /** A whole frame: the interface drawn, then the render thread's turn and the render queue run. */
    private static void frame() {
        render();
        RenderThread.flush();
        SpriteRenderer.flush();
    }

    private static double show(KahluaTable text, Object mod, Object... pairs) { return (Double)FormulasTest.call(text, "show", mod, table(pairs)).get(0); }

    private static List<String> names() {
        var names = new ArrayList<String>();
        for (Object[] call : TextManager.calls) names.add((String)call[0]);
        return names;
    }

    private static List<Object[]> draws() {
        var draws = new ArrayList<Object[]>();
        for (Object[] call : TextManager.calls) if ("text".equals(call[0])) draws.add(call);
        return draws;
    }

    private static List<Object[]> quads() {
        var quads = new ArrayList<Object[]>();
        for (Object[] call : TextManager.calls) if ("quad".equals(call[0])) quads.add(call);
        return quads;
    }

    private static boolean hasQuads(Object texture) {
        for (Object[] quad : quads()) if (texture == null ? quad[1] != null : quad[1] == texture) return true;
        return false;
    }

    /** Another picture than this one, as quads drawn show it; null for any. */
    private static Object other(Object picture) {
        for (Object[] quad : quads()) if (quad[1] != picture) return quad[1];
        return new Object();
    }

    private static Object[] last(String words) {
        Object[] found = null;
        for (Object[] call : draws()) if (words.equals(call[5])) found = call;
        return found;
    }

    private static Object[] call(String name) {
        for (Object[] call : TextManager.calls) if (name.equals(call[0])) return call;
        return null;
    }

    private static double alpha(Object[] draw) { return (Double)draw[9]; }

    private static void drawn(Object[] draw, UIFont font, double x, double y, double zoom, String words, double r, double g, double b, double a) {
        check(draw != null && draw[1] == font && near((Double)draw[2], x) && near((Double)draw[3], y) && near((Double)draw[4], zoom) && words.equals(draw[5])
            && near((Double)draw[6], r) && near((Double)draw[7], g) && near((Double)draw[8], b) && near((Double)draw[9], a),
            "Drawn " + Arrays.toString(draw) + ", expected " + font + " at " + x + ", " + y + " zoom " + zoom + " " + words + " " + r + "," + g + "," + b + "," + a);
    }

    private static void rejects(KahluaTable text, String message, String name, Object... arguments) {
        try { FormulasTest.call(text, name, arguments); }
        catch (IllegalArgumentException expected) {
            check(expected.getMessage().startsWith("PZExtAPI.text." + name + ": ") && expected.getMessage().contains(message), expected.getMessage());
            return;
        }
        throw new AssertionError(name + " accepted bad arguments: " + message);
    }

    private static boolean near(double value, double expected) { return Math.abs(value - expected) < 1e-4; }

    private static KahluaTable table(Object... pairs) {
        var result = LuaManager.platform.newTable();
        for (int index = 0; index < pairs.length; index += 2) result.rawset(pairs[index], pairs[index + 1]);
        return result;
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
